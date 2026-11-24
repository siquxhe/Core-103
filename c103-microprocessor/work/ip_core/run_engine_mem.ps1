# 103 复刻 · 2b 引擎旁路 ↔ 共享行为 RAM 集成回归
# 用法：pwsh -File run_engine_mem.ps1
# 判据：引擎搬运后目的区逐字等于源区、源区未改写（tb_engine_mem 内置 PASS/FAIL）。

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_em.vvp"
$log = Join-Path $reg "engine-mem.log"

Write-Host "=== compile tb_engine_mem ==="
& iverilog -o $vvp -s tb_engine_mem -y (Join-Path $here core) `
    -y (Join-Path $here rtl) -y (Join-Path $here tb) `
    (Join-Path $here "core\memory.v") (Join-Path $here "rtl\copy_engine.v") `
    (Join-Path $here "..\rtl\mem_write_arbiter.v") `
    (Join-Path $here "tb\tb_engine_mem.v")
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_engine_mem ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "ENGINE-MEM INTEGRATION PASS") {
    Write-Host "ENGINE-MEM INTEGRATION PASS"
} else {
    Write-Host "ENGINE-MEM INTEGRATION FAIL"
    exit 1
}
