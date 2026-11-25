# 仲裁器双主同拍并发定向加压：互斥 / 不丢写 / 轮转公平 / 满队背压
# 用法：pwsh -File run_arb_concur.ps1

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\w64devkit\bin;C:\Program Files\Git\usr\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_arbconcur.vvp"
$log = Join-Path $reg "arb-concur.log"

$sources = @()
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_arb_concur.v")

Write-Host "=== compile tb_arb_concur ==="
& iverilog -o $vvp -s tb_arb_concur -y (Join-Path $here "..\rtl") -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_arb_concur ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "ARBCONC E2E PASS") {
    Write-Host "ARBCONC PASS"
} else {
    Write-Host "ARBCONC FAIL"
    exit 1
}
