# 103 复刻 · 核心固件轮询闭环：固件读命令块 DONE → 条件跳转循环 → 写 ACK → ctrl 握手回 IDLE
# 用法：pwsh -File run_fw_poll.ps1

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$reg  = Join-Path (Split-Path -Parent $here) "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

$vvp = Join-Path $here "tb_fwpoll.vvp"
$log = Join-Path $reg "fw-poll.log"

$sources = @()
Get-ChildItem (Join-Path $here "core") -Filter *.v | ForEach-Object { $sources += $_.FullName }
$sources += (Join-Path $here "..\rtl\copy_engine.v")
$sources += (Join-Path $here "..\rtl\engine_ctrl.v")
$sources += (Join-Path $here "..\rtl\mem_write_arbiter.v")
$sources += (Join-Path $here "tb\tb_fw_poll.v")

Write-Host "=== compile tb_fw_poll ==="
& iverilog -o $vvp -s tb_fw_poll -y (Join-Path $here core) `
    -y (Join-Path $here "..\rtl") -y (Join-Path $here tb) $sources
if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL"; exit 1 }

Write-Host "=== run tb_fw_poll ==="
Push-Location $here
$out = & vvp $vvp | Tee-Object -FilePath $log
Pop-Location

if ($out -match "FW-POLL E2E PASS") {
    Write-Host "FW-POLL PASS"
} else {
    Write-Host "FW-POLL FAIL"
    exit 1
}
