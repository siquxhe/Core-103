# P0-2 镜像装载链路回归（路线 A 仿真闭环）
# 链路：冻结 input.103 + 段定义 -> image-pack -> image.bin/.hex
#   C 侧：simulator -m image.bin -> output.103（MD5 比对冻结基线）+ 坏镜像报错分支
#   RTL 侧：iverilog/vvp 跑 image_loader 正向 tb + 报错 tb（坏 hex 定向用例）
# 位置：Core-103/tools/；项目根为本脚本上两级（tools -> Core-103 -> 项目根）。

$ErrorActionPreference = "Stop"
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $toolsDir)

# 工具链 PATH：纯环境变量定位，未设置沿用系统 PATH（见 tools/toolchain.ps1）
. (Join-Path $toolsDir "toolchain.ps1")
Initialize-CoreToolchain

$packDir = Join-Path $root "tape-converter\src_imagepack"
$packExe = Join-Path $packDir "image-pack.exe"
$simDir  = Join-Path $root "simulator\src_c"
$simExe  = Join-Path $simDir "simulator.exe"
$ipCore  = Join-Path $root "c103-microprocessor\work\ip_core"
$rtlDir  = Join-Path $root "c103-microprocessor\work\rtl"
$ref103  = Join-Path $root "test-program\04_and\input.103"

# 04_and 段定义（八进制）：程序段 0000-1200 -> 0000；数据段 3000-3777 -> 3000。
$segDef = @"
entry 0000
seg 0 0000 0000 1200
seg 1 3000 3000 3777
"@

# 正向基线 MD5（镜像通路 04_and output.103，320 行）。
$BASE_MD5 = "00a84cb87f46cbab5a2e0f1f73a909d2"

# ---- 缺失则编译打包器 / 模拟器 ----
if (-not (Test-Path $packExe)) {
    Push-Location $packDir
    & gcc -O2 -I. main.c -o image-pack.exe
    if ($LASTEXITCODE -ne 0) { Write-Host "image-pack 编译失败"; exit 1 }
    Pop-Location
}
if (-not (Test-Path $simExe)) {
    Push-Location $simDir
    & gcc -O2 -I. main.c 103.c -o simulator.exe
    if ($LASTEXITCODE -ne 0) { Write-Host "simulator 编译失败"; exit 1 }
    Pop-Location
}

$work = Join-Path $env:TEMP "c103-img-regress"
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$segPath = Join-Path $work "case.seg"
Set-Content $segPath $segDef -Encoding ascii
Copy-Item $ref103 (Join-Path $work "input.103") -Force

$bin = Join-Path $work "case.bin"
$hex = Join-Path $work "case.hex"
& $packExe $segPath (Join-Path $work "input.103") -o $bin --hex $hex 2>&1 |
    ForEach-Object { Write-Host "pack: $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "image-pack 失败"; exit 1 }

$results = @()
function Add-Row($stage, $case, $result, $note) {
    $script:results += [pscustomobject]@{ Stage=$stage; Case=$case; Result=$result; Note=$note }
}

# ============ C 侧正向 ============
Push-Location $work
& $simExe -m case.bin 2>forward.err | Out-Null
$simExit = $LASTEXITCODE
Pop-Location
$out103 = Join-Path $work "output.103"
if ($simExit -eq 0 -and (Test-Path $out103)) {
    $h = (Get-FileHash $out103 -Algorithm MD5).Hash.ToLower()
    if ($h -eq $BASE_MD5) { Add-Row "C-forward" "04_and" "PASS" "MD5 $h" }
    else { Add-Row "C-forward" "04_and" "DIFF" "got $h expect $BASE_MD5" }
} else {
    Add-Row "C-forward" "04_and" "FAIL" "sim exit=$simExit $(Get-Content (Join-Path $work 'forward.err') -Raw)"
}

# ============ C 侧报错分支 ============
# 场景：名称 / 改动字索引 / 新字(hex, 空=xor1) / 截断字数(0=不截断) / 预期关键字
$cBad = @(
    @{ n="magic";   w=0;  v="00000000"; cut=0;   key="魔数" },
    @{ n="cksum";   w=10; v=$null;      cut=0;   key="校验和" },
    @{ n="type";    w=2;  v="02000000"; cut=0;   key="类型" },
    @{ n="dst";     w=2;  v="00000fff"; cut=0;   key="目的越界" },
    @{ n="len0";    w=3;  v="00000000"; cut=0;   key="字数为 0" },
    @{ n="nseg0";   w=1;  v="08000000"; cut=0;   key="段数非法" },
    @{ n="ver";     w=1;  v="10000002"; cut=0;   key="版本" },
    @{ n="algo";    w=1;  v="09000002"; cut=0;   key="算法" },
    @{ n="off";     w=2;  v="00fff000"; cut=0;   key="偏移越界" },
    @{ n="short";   w=0;  v=$null;      cut=1150; key="字数与段表不符" }
)

function Set-Word([byte[]]$b, [int]$w, [uint32]$v) {
    $o = $w * 4
    $b[$o]     = [byte]($v -band 0xff)
    $b[$o + 1] = [byte](($v -shr 8) -band 0xff)
    $b[$o + 2] = [byte](($v -shr 16) -band 0xff)
    $b[$o + 3] = [byte](($v -shr 24) -band 0xff)
}

foreach ($b in $cBad) {
    $src = [System.IO.File]::ReadAllBytes($bin)
    if ($b.cut -gt 0) {
        $data = New-Object byte[] ($b.cut * 4)
        [Array]::Copy($src, $data, $data.Length)
    } else {
        $data = New-Object byte[] $src.Length
        [Array]::Copy($src, $data, $src.Length)
        if ($null -ne $b.v) {
            Set-Word $data $b.w ([Convert]::ToUInt32($b.v, 16))
        } else {
            $o = $b.w * 4
            $data[$o] = $data[$o] -bxor 1
        }
    }
    $badBin = Join-Path $work ("bad-" + $b.n + ".bin")
    [System.IO.File]::WriteAllBytes($badBin, $data)

    Push-Location $work
    $errFile = Join-Path $work ("bad-" + $b.n + ".err")
    & $simExe -m $badBin 2>$errFile | Out-Null
    $code = $LASTEXITCODE
    Pop-Location
    $msg = ((Get-Content $errFile -Raw) ?? "").Trim()
    if ($code -ne 0 -and $msg -like "*$($b.key)*") {
        Add-Row "C-error" $b.n "PASS" "exit=$code"
    } else {
        Add-Row "C-error" $b.n "FAIL" "exit=$code msg=$msg"
    }
}

# ============ RTL 正向 ============
$fwVvp = Join-Path $ipCore "tb_im.vvp"
& iverilog -o $fwVvp -s tb_image_loader -y (Join-Path $ipCore core) `
    -y (Join-Path $ipCore rtl) -y (Join-Path $ipCore tb) `
    (Join-Path $ipCore "core\memory.v") (Join-Path $ipCore "..\rtl\mem_write_arbiter.v") `
    (Join-Path $rtlDir "image_loader.v") (Join-Path $ipCore "tb\tb_image_loader.v")
if ($LASTEXITCODE -ne 0) { Write-Host "RTL 正向 tb 编译失败"; exit 1 }
Copy-Item $hex (Join-Path $ipCore "case.hex") -Force
Push-Location $ipCore
$fwOut = & vvp $fwVvp 2>$null
Pop-Location
if ($fwOut -match "RESULT: PASS") { Add-Row "RTL-forward" "04_and" "PASS" (($fwOut | Select-String "PASS=\d+").Matches.Value) }
else { Add-Row "RTL-forward" "04_and" "FAIL" ($fwOut -join " ") }

# ============ RTL 报错分支 ============
# 场景：名称 / hex 行索引 / 新字(hex, 空=xor1) / 期望错误码
$rBad = @(
    @{ n="magic";  l=0; v="00000000"; code=2  },
    @{ n="cksum";  l=10; v=$null;     code=10 },
    @{ n="type";   l=2; v="02000000"; code=6  },
    @{ n="dst";    l=2; v="00000fff"; code=8  },
    @{ n="len0";   l=3; v="00000000"; code=7  },
    @{ n="nseg0";  l=1; v="08000000"; code=4  },
    @{ n="ver";    l=1; v="10000002"; code=3  },
    @{ n="algo";   l=1; v="09000002"; code=3  },
    @{ n="off";    l=2; v="00fff000"; code=9  }
)
$errVvp = Join-Path $ipCore "tb_ime.vvp"
$baseHex = Get-Content $hex
foreach ($b in $rBad) {
    $lines = $baseHex.Clone()
    if ($null -ne $b.v) { $lines[$b.l] = $b.v }
    else {
        $orig = [Convert]::ToUInt32($lines[$b.l], 16)
        $lines[$b.l] = ("{0:x8}" -f ($orig -bxor 1))
    }
    Set-Content (Join-Path $ipCore "case.hex") $lines -Encoding ascii

    & iverilog -o $errVvp -s tb_image_loader_err `
        -P "tb_image_loader_err.EXPECT_ERR_CODE=$($b.code)" `
        -y (Join-Path $ipCore core) -y (Join-Path $ipCore rtl) -y (Join-Path $ipCore tb) `
        (Join-Path $ipCore "core\memory.v") (Join-Path $ipCore "..\rtl\mem_write_arbiter.v") `
        (Join-Path $rtlDir "image_loader.v") (Join-Path $ipCore "tb\tb_image_loader_err.v")
    if ($LASTEXITCODE -ne 0) { Add-Row "RTL-error" $b.n "FAIL" "编译失败"; continue }

    Push-Location $ipCore
    $rOut = & vvp $errVvp 2>$null
    Pop-Location
    if ($rOut -match "RESULT: PASS") { Add-Row "RTL-error" $b.n "PASS" "code=$($b.code)" }
    else { Add-Row "RTL-error" $b.n "FAIL" ($rOut -join " ") }
}
# 恢复正向 hex
Copy-Item $hex (Join-Path $ipCore "case.hex") -Force

# ============ 汇总 ============
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$pass = ($results | Where-Object Result -eq "PASS").Count
$fail = ($results | Where-Object Result -ne "PASS").Count
Write-Host ""
Write-Host ("镜像装载回归：PASS {0} / FAIL {1}" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
