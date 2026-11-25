# 103 复刻 · 传送变体覆盖：005/015/045/055/064（引擎搬运后核心目的区执行）
# 用法：pwsh -File run_move_cov.ps1

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_mc.vvp"
$log = Join-Path $reg "move-cov.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_move_cov.v")

Write-Host "=== compile tb_move_cov ==="
& iverilog -o $vvp -s tb_move_cov -y (Join-Path $here core) `
    -y (Join-Path $here rtl) -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_move_cov ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "MOVE-COV FAIL") {
    Write-Host "MOVE-COV FAIL"
    exit 1
} else {
    Write-Host "MOVE-COV PASS"
}
