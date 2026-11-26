# 103 复刻 · 指令覆盖回归：位与 / 无条件跳转（引擎搬运后核心目的区执行）
# 用法：pwsh -File run_inst_cov.ps1

$ErrorActionPreference = "Stop"
$coreRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $coreRoot "tools\toolchain.ps1")
Initialize-CoreToolchain

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_ic.vvp"
$log = Join-Path $reg "inst-cov.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_inst_cov.v")

Write-Host "=== compile tb_inst_cov ==="
& iverilog -o $vvp -s tb_inst_cov -y (Join-Path $here core) `
    -y (Join-Path $here rtl) -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_inst_cov ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "INST-COV FAIL") {
    Write-Host "INST-COV FAIL"
    exit 1
} else {
    Write-Host "INST-COV PASS"
}
