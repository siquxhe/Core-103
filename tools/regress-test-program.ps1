# 批量回归 test-program 21 例（冻结输入，MD5 比对）
# 链路：冻结 input.bin -> simulator.exe -> output.103 -> char2tape.exe -> output.bin
# 另校验：char2tape 对冻结 input.103 重新汇编的 input.bin 与仓库内 input.bin 一致。
# 注意：helper.py 未设随机种子，重新生成 input.103 会偏离冻结参考，故本脚本不跑 helper.py。
# 位置：Core-103/tools/；项目根为本脚本上两级（tools -> Core-103 -> 项目根）。

$ErrorActionPreference = "Stop"
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $toolsDir)
$tp      = Join-Path $root "test-program"
$sim     = Join-Path $root "simulator\src_c\simulator.exe"
$c2t     = Join-Path $root "tape-converter\src_char2tape\char2tape.exe"

# 工具链 PATH：纯环境变量定位，未设置沿用系统 PATH（见 tools/toolchain.ps1）
. (Join-Path $toolsDir "toolchain.ps1")
Initialize-CoreToolchain

# 解析 README 参考 MD5：<hash>  <case>/output.bin
$ref = @{}
foreach ($line in Get-Content (Join-Path $tp "README.md")) {
    if ($line -match '^\s*([0-9a-fA-F]{32})\s+([^/\s]+)/output\.bin') {
        $ref[$matches[2]] = $matches[1].ToLower()
    }
}

# 这些用例的 Makefile 不调用模拟器（面板/启动寄存器类，由 Verilator 测试台驱动）
$panelCases = @("09_strt", "10_pnl", "11_sw")

$workRoot = Join-Path $env:TEMP "c103-regress"
if (Test-Path $workRoot) { Remove-Item $workRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$results = @()
$cases = Get-ChildItem $tp -Directory | Sort-Object Name

foreach ($c in $cases) {
    $name = $c.Name
    $work = Join-Path $workRoot $name
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $row = [ordered]@{
        Case      = $name
        Asm       = "-"
        SimExit   = "-"
        OutOurs   = "-"
        OutRef    = $ref[$name]
        Result    = ""
        Note      = ""
    }

    # 1) 汇编一致性：冻结 input.103 -> input.bin，比对仓库内冻结 input.bin
    $src103 = Join-Path $c.FullName "input.103"
    $srcBin = Join-Path $c.FullName "input.bin"
    if ((Test-Path $src103) -and (Test-Path $srcBin)) {
        Copy-Item $src103 (Join-Path $work "input.103") -Force
        & $c2t (Join-Path $work "input.103") -o (Join-Path $work "asm_input.bin") 2>$null
        $hAsm  = (Get-FileHash (Join-Path $work "asm_input.bin") -Algorithm MD5).Hash.ToLower()
        $hRefB = (Get-FileHash $srcBin -Algorithm MD5).Hash.ToLower()
        $row.Asm = if ($hAsm -eq $hRefB) { "PASS" } else { "DIFF" }
    } else {
        $row.Asm = "N/A"
    }

    # 2) 模拟器回归（面板类用例跳过）
    if ($panelCases -contains $name) {
        $row.Result = "N/A(面板类)"
        $row.Note   = "Makefile 不调用 simulator"
    } else {
        Copy-Item $srcBin (Join-Path $work "input.bin") -Force
        Push-Location $work
        # 开关按用例显式写出（避免 pwsh 数组展开对 `-X` 参数的拆分/加连字符问题）
        switch ($name) {
            "01_io2" { & $sim -d -D input.bin 2>$null | Out-Null }
            "01_io3" { & $sim -S input.bin 2>$null | Out-Null }
            default  { & $sim input.bin 2>$null | Out-Null }
        }
        $row.SimExit = $LASTEXITCODE
        Pop-Location

        $out103 = Join-Path $work "output.103"
        if (Test-Path $out103) {
            & $c2t $out103 -o (Join-Path $work "output.bin") 2>$null
            $hOut = (Get-FileHash (Join-Path $work "output.bin") -Algorithm MD5).Hash.ToLower()
            $row.OutOurs = $hOut
            $row.Result = if ($hOut -eq $ref[$name]) { "PASS" } else { "DIFF" }
        } else {
            $row.Result = "NO-OUTPUT"
            $row.Note   = "模拟器未生成 output.103"
        }
    }

    $results += [pscustomobject]$row
}

$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$pass = ($results | Where-Object Result -eq "PASS").Count
$diff = ($results | Where-Object Result -eq "DIFF").Count
$na   = ($results | Where-Object Result -like "N/A*").Count
$noout = ($results | Where-Object Result -eq "NO-OUTPUT").Count
$asmPass = ($results | Where-Object Asm -eq "PASS").Count
$asmDiff = ($results | Where-Object Asm -eq "DIFF").Count
Write-Host ""
Write-Host ("模拟器回归：PASS {0} / DIFF {1} / N/A {2} / 无输出 {3}" -f $pass, $diff, $na, $noout)
Write-Host ("汇编一致性：PASS {0} / DIFF {1}" -f $asmPass, $asmDiff)
