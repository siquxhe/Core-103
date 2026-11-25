# L3-c 端到端：image-pack 生成三段背靠背固件镜像 -> loader 灌主存 -> 联锁 -> 固件逐段发命令块/轮询/ACK 握手
# 用法：pwsh -File run_loader_fw2.ps1

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\w64devkit\bin;C:\Program Files\Git\usr\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
# $here = <root>/c103-microprocessor/work/ip_core；项目根再上三级
$root   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))
$reg    = Join-Path (Split-Path -Parent $here) "regress"
$l3dir  = Join-Path $reg "l3-loader-firmware"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$packDir = Join-Path $root "tape-converter\src_imagepack"
$packExe = Join-Path $packDir "image-pack.exe"
$seg     = Join-Path $l3dir "fw_l3c.seg"
$src103  = Join-Path $l3dir "fw_l3c.103"

if (-not (Test-Path $packExe)) {
    Push-Location $packDir
    & gcc -O2 -I. main.c -o image-pack.exe
    if ($LASTEXITCODE -ne 0) { Write-Host "image-pack 编译失败"; exit 1 }
    Pop-Location
}

$bin = Join-Path $here "case.bin"
$hex = Join-Path $here "case.hex"
& $packExe $seg $src103 -o $bin --hex $hex 2>&1 | ForEach-Object { Write-Host "pack: $_" }
if ($LASTEXITCODE -ne 0) { Write-Host "image-pack 失败"; exit 1 }

$vvp = Join-Path $here "tb_loaderfw2.vvp"
$log = Join-Path $reg "loader-fw2.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "..\rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\engine_ctrl.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "..\rtl\image_loader.v")
$sources += (Join-Path $here "tb\tb_loader_fw2.v")

Write-Host "=== compile tb_loader_fw2 ==="
& iverilog -o $vvp -s tb_loader_fw2 -y (Join-Path $here core) `
    -y (Join-Path $here "..\rtl") -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_loader_fw2 ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "LOADER-FW2 E2E PASS") {
    Write-Host "LOADER-FW2 PASS"
} else {
    Write-Host "LOADER-FW2 FAIL"
    exit 1
}
