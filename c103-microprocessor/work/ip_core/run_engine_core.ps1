# 103 复刻 · 2b 端到端回归：引擎搬运后核心从目的区取指执行
# 用法：pwsh -File run_engine_core.ps1
# 场景：最小加法程序经引擎两段搬运到目的区，核心从 0000 执行，校验 3001/3002 == 7。

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_ec.vvp"
$log = Join-Path $reg "engine-core.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_engine_core.v")

Write-Host "=== compile tb_engine_core ==="
& iverilog -o $vvp -s tb_engine_core -y (Join-Path $here core) `
    -y (Join-Path $here rtl) -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_engine_core ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "ENGINE-CORE E2E PASS") {
    Write-Host "ENGINE-CORE E2E PASS"
} else {
    Write-Host "ENGINE-CORE E2E FAIL"
    exit 1
}
