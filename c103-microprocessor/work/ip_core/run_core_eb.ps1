# 103 复刻 · 核心端到端 iverilog 回归（第二步 2a：核心直接执行冻结程序）
# 用法：pwsh -File run_core_eb.ps1
# 产物：test/output.bin；与 test/output.bin.ref 做 MD5 比对。

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp  = Join-Path $here "tb_eb.vvp"
$log  = Join-Path $reg "core-eb.log"

$sources = @()
foreach ($sub in @("core", "include", "shell", "tb")) {
    Get-ChildItem (Join-Path $here $sub) -Filter *.v | ForEach-Object { $sources += $_.FullName }
}
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")

Write-Host "=== compile tb_core_eb ==="
& iverilog -o $vvp -s tb_core_eb -y (Join-Path $here core) `
    -y (Join-Path $here include) -y (Join-Path $here shell) -y (Join-Path $here tb) `
    $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_core_eb ==="
Push-Location $here
& vvp $vvp | Tee-Object -FilePath $log
Pop-Location

$out = Join-Path $here "test\output.bin"
$ref = Join-Path $here "test\output.bin.ref"
if (-not (Test-Path $out)) { Write-Host "FAIL output.bin not produced"; exit 1 }

$hOut = (Get-FileHash $out -Algorithm MD5).Hash.ToLower()
$hRef = (Get-FileHash $ref -Algorithm MD5).Hash.ToLower()
Write-Host "output.bin      MD5: $hOut"
Write-Host "output.bin.ref  MD5: $hRef"
if ($hOut -eq $hRef) {
    Write-Host "CORE E2E PASS: output matches reference"
} else {
    Write-Host "CORE E2E FAIL: output differs from reference"
    exit 1
}
