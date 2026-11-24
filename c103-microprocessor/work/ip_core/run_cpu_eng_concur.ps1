# 103 复刻 · CPU 写主 ↔ 拷贝引擎写主 并发公平仲裁集成回归
# 用法：pwsh -File run_cpu_eng_concur.ps1
# 判据：引擎搬运目的区逐字落位、CPU 并发写全部落数组、源区未改写、授权互斥。

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_concur.vvp"
$log = Join-Path $reg "cpu-eng-concur.log"

Write-Host "=== compile tb_cpu_eng_concur ==="
& iverilog -o $vvp -s tb_cpu_eng_concur -y (Join-Path $here core) `
    -y (Join-Path $here rtl) -y (Join-Path $here tb) `
    (Join-Path $here "core\memory.v") (Join-Path $here "rtl\copy_engine.v") `
    (Join-Path $here "..\rtl\mem_write_arbiter.v") `
    (Join-Path $here "tb\tb_cpu_eng_concur.v")
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_cpu_eng_concur ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "CPU-ENG CONCURRENCY PASS") {
    Write-Host "CPU-ENG CONCURRENCY PASS"
} else {
    Write-Host "CPU-ENG CONCURRENCY FAIL"
    exit 1
}
