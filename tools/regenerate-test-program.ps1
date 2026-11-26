# 从 helper.py 重新生成 test-program 用例（固定种子，可复现），并跑通模拟器 + 纸带转换链路。
# 产物写入 test-program-gen\<case>\，不覆盖仓库内冻结的 input/output 参考文件。
# 链路：gen_helper.py(种子) -> input.103 -> char2tape -> input.bin -> simulator -> output.103 -> char2tape -> output.bin
# 位置：Core-103/tools/；项目根为本脚本上两级（tools -> Core-103 -> 项目根）。

$ErrorActionPreference = "Stop"
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $toolsDir)
$tp      = Join-Path $root "test-program"
$genRoot = Join-Path $root "test-program-gen"
$sim     = Join-Path $root "simulator\src_c\simulator.exe"
$c2t     = Join-Path $root "tape-converter\src_char2tape\char2tape.exe"
$runner  = Join-Path $toolsDir "gen_helper.py"

# 工具链 PATH：纯环境变量定位，未设置沿用系统 PATH（见 tools/toolchain.ps1）
. (Join-Path $toolsDir "toolchain.ps1")
Initialize-CoreToolchain

if (Test-Path $genRoot) { Remove-Item $genRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $genRoot | Out-Null

$results = @()
$cases = Get-ChildItem $tp -Directory | Sort-Object Name
$idx = 0

foreach ($c in $cases) {
    $idx++
    $helper = Join-Path $c.FullName "helper.py"
    if (-not (Test-Path $helper)) {
        $results += [pscustomobject]@{ Case=$c.Name; Stage="SKIP"; Exit="-"; Lines="-"; Note="无 helper.py（面板类，由 Verilator 驱动）" }
        continue
    }

    $work = Join-Path $genRoot $c.Name
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $seed = 103000 + $idx

    # 1) 生成 input.103（固定种子）
    & py -3 $runner $helper $seed > (Join-Path $work "input.103") 2> (Join-Path $work "gen.err")
    $genExit = $LASTEXITCODE

    # 2) 汇编成纸带
    & $c2t (Join-Path $work "input.103") -o (Join-Path $work "input.bin") 2>$null
    $asmExit = $LASTEXITCODE

    # 3) 跑模拟器（开关与各用例 Makefile 配方一致；显式分支避免 pwsh 数组拆参）
    Push-Location $work
    switch ($c.Name) {
        "01_io2" { & $sim -d -D input.bin 2>$null | Out-Null }
        default  { & $sim input.bin 2>$null | Out-Null }
    }
    $simExit = $LASTEXITCODE
    Pop-Location

    # 4) 输出文本 -> 纸带
    $out103 = Join-Path $work "output.103"
    $outLines = "-"
    if (Test-Path $out103) {
        $outLines = (Get-Content $out103).Count
        & $c2t $out103 -o (Join-Path $work "output.bin") 2>$null
    }

    $results += [pscustomobject]@{
        Case    = $c.Name
        Seed    = $seed
        GenExit = $genExit
        AsmExit = $asmExit
        SimExit = $simExit
        OutLines= $outLines
        Note    = if ($genExit -ne 0) { "helper 生成失败" } elseif (-not (Test-Path $out103)) { "模拟器无输出" } else { "OK" }
    }
}

$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$ok = ($results | Where-Object Note -eq "OK").Count
Write-Host "`n生成完成：OK $ok / 其余 $($results.Count - $ok)"
