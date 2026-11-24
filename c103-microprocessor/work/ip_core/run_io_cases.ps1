# 103 复刻 · IO 输入输出 / 进制打包端到端回归
# 复用 tb_core_eb 纸带链路：从冻结 test-program/<case> 铺 input.bin/task.seq，
# vvp 跑完比对 output.bin MD5 与 C 模拟器冻结参考（README 哈希）。
#   io  : 八进制双向回环
#   io2 : 十进制 BCD 双向回环（-d -D，7 位带符号）
#   io3 : 输出后停机（-S）
# 用法：pwsh -File run_io_cases.ps1

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$work = Split-Path -Parent $here
# $here = c103-microprocessor/work/ip_core；项目根为其上三级（test-program 在项目根）
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))
$tp   = Join-Path $root "test-program"
$reg  = Join-Path $work "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$testDir = Join-Path $here "test"
$vvp     = Join-Path $here "tb_eb.vvp"
$log     = Join-Path $reg "io-cases.log"

# 冻结参考 MD5（README.md）
$cases = @(
    @{ Name = "01_io";  Ref = "67146a4fa9da8dfa0c01dbb5fb21e994" },
    @{ Name = "01_io2"; Ref = "843b2c87e004d8c18c8b43b6ebed6ceb" },
    @{ Name = "01_io3"; Ref = "1437c3c3d04b76d0535baa23da09f9ab" }
)

# ---- 编译一次 ----
$sources = @()
foreach ($sub in @("core", "include", "shell", "tb")) {
    Get-ChildItem (Join-Path $here $sub) -Filter *.v | ForEach-Object { $sources += $_.FullName }
}
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
Write-Host "=== compile tb_core_eb ==="
& iverilog -o $vvp -s tb_core_eb -y (Join-Path $here core) `
    -y (Join-Path $here include) -y (Join-Path $here shell) -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

# 记录进入前的 test/ 基线，跑完恢复
$backup = Join-Path $testDir "oct"
$hadBackup = Test-Path $backup

$results = @()
Push-Location $here
try {
    foreach ($c in $cases) {
        $src = Join-Path $tp $c.Name
        Copy-Item (Join-Path $src "input.bin")  (Join-Path $testDir "input.bin")  -Force
        Copy-Item (Join-Path $src "task.seq")   (Join-Path $testDir "task.seq")  -Force
        Copy-Item (Join-Path $src "output.bin")  (Join-Path $testDir "output.bin.ref") -Force

        Write-Host "=== run $($c.Name) ==="
        $out = & vvp $vvp 2>&1
        $out | Tee-Object -FilePath $log -Append | Out-Host

        $hOut = (Get-FileHash (Join-Path $testDir "output.bin") -Algorithm MD5).Hash.ToLower()
        $ok = ($hOut -eq $c.Ref)
        $results += [pscustomobject]@{ Case = $c.Name; Out = $hOut; Ref = $c.Ref; Result = if ($ok) { "PASS" } else { "FAIL" } }
        if (-not $ok) { Write-Host "$($c.Name) FAIL: $hOut != $($c.Ref)" }
    }
} finally {
    Pop-Location
    # 恢复进入前的 core-eb 基线纸带
    if ($hadBackup) {
        Copy-Item (Join-Path $backup "input.bin")      (Join-Path $testDir "input.bin")      -Force
        Copy-Item (Join-Path $backup "task.seq")       (Join-Path $testDir "task.seq")       -Force
        Copy-Item (Join-Path $backup "output.bin.ref") (Join-Path $testDir "output.bin.ref") -Force
    }
}

$results | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
$fail = ($results | Where-Object Result -eq "FAIL").Count
if ($fail -eq 0) { Write-Host "IO-CASES PASS"; exit 0 } else { Write-Host "IO-CASES FAIL"; exit 1 }
