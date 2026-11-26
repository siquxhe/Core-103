# 103 复刻 · 引擎子系统背靠背加压回归
# 装配：memory（含写仲裁器）+ engine_ctrl + copy_engine。
# 覆盖：正向/反向重叠、长度 1、长段、背靠背重复、越界源/目的、零长。
# 判据：目的区逐字 == 源区；错误段 err_code 匹配；ACK 后引擎回 IDLE。
# 用法：pwsh -File run_engine_backpressure.ps1

$ErrorActionPreference = "Stop"
$coreRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $coreRoot "tools\toolchain.ps1")
Initialize-CoreToolchain

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb\eng_bp.vvp"
$log = Join-Path $reg "engine-backpressure.log"

$sources = @()
$sources += (Join-Path $here "core\memory.v")
$sources += (Join-Path $here "..\rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\engine_ctrl.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_engine_backpressure.v")

Write-Host "=== compile tb_engine_backpressure ==="
& iverilog -o $vvp -s tb_engine_backpressure `
    -y (Join-Path $here core) `
    -y (Join-Path $here "..\rtl") -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_engine_backpressure ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "BACKTOBACK E2E PASS") {
    Write-Host "BACKTOBACK PASS"
} else {
    Write-Host "BACKTOBACK FAIL"
    exit 1
}
