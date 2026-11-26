# 103 复刻 · 装配模块闭环回归：命令块取参 → 引擎搬运 → 状态镜像 → ack 握手
# 用法：pwsh -File run_engine_ctrl.ps1

$ErrorActionPreference = "Stop"
$coreRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $coreRoot "tools\toolchain.ps1")
Initialize-CoreToolchain

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_ectrl.vvp"
$log = Join-Path $reg "engine-ctrl.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "..\rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\engine_ctrl.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_engine_ctrl.v")

Write-Host "=== compile tb_engine_ctrl ==="
& iverilog -o $vvp -s tb_engine_ctrl -y (Join-Path $here core) `
    -y (Join-Path $here "..\rtl") -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_engine_ctrl ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "ENG-CTRL E2E PASS") {
    Write-Host "ENG-CTRL PASS"
} else {
    Write-Host "ENG-CTRL FAIL"
    exit 1
}
