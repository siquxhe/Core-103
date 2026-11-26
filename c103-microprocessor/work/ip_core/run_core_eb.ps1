# 103 复刻 · 核心端到端 iverilog 回归（第二步 2a：核心直接执行冻结程序）
# 用法：pwsh -File run_core_eb.ps1
# 产物：test/output.bin；与 test/output.bin.ref 做 MD5 比对。

$ErrorActionPreference = "Stop"
$coreRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $coreRoot "tools\toolchain.ps1")
Initialize-CoreToolchain

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
$match = ($hOut -eq $hRef)
$lineOut = "output.bin      MD5: $hOut"
$lineRef = "output.bin.ref  MD5: $hRef"
$lineVerdict = if ($match) { "CORE E2E PASS: output matches reference" } else { "CORE E2E FAIL: output differs from reference" }
Write-Host $lineOut
Write-Host $lineRef
Write-Host $lineVerdict
# 哈希比对结论一并写入回归日志，保证日志自含证据链（不依赖控制台/退出码回溯）
Add-Content -Path $log -Value $lineOut, $lineRef, $lineVerdict
if (-not $match) { exit 1 }
