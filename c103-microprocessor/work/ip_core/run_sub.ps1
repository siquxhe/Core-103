# 103 复刻 · 减法指令覆盖回归（符号组合 + 零结果）
# 用法：pwsh -File run_sub.ps1

$ErrorActionPreference = "Stop"
$coreRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $coreRoot "tools\toolchain.ps1")
Initialize-CoreToolchain

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_sub.vvp"
$log = Join-Path $reg "sub-cov.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_sub.v")

Write-Host "=== compile tb_sub ==="
& iverilog -o $vvp -s tb_sub -y (Join-Path $here core) `
    -y (Join-Path $here rtl) -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_sub ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "SUB-COV FAIL") {
    Write-Host "SUB-COV FAIL"
    exit 1
} else {
    Write-Host "SUB-COV PASS"
}
