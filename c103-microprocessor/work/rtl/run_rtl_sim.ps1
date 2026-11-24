# 103 复刻 · RTL 引擎 + 写仲裁 功能回归（Icarus iverilog/vvp）
# 用法：pwsh -File run_rtl_sim.ps1
# 产物日志：../regress/rtl-engine-selftest.log、rtl-arbiter-selftest.log

$ErrorActionPreference = "Stop"
$env:Path = "C:\Program Files\Git\usr\bin;C:\Program Files\w64devkit\bin;C:\oss-cad-suite\bin;C:\oss-cad-suite\lib"

$work = Split-Path -Parent $PSScriptRoot          # work/
$rtl  = Join-Path $work "rtl"
$tb   = Join-Path $work "tb_rtl"
$reg  = Join-Path $work "regress"
New-Item -ItemType Directory -Force -Path $reg | Out-Null

function Invoke-Sim {
    param(
        [string]$Top,
        [string[]]$Sources,
        [string]$LogName
    )
    $vvp = Join-Path $work "$Top.vvp"
    Write-Host "=== compile $Top ==="
    & iverilog -o $vvp -s $Top @Sources
    if ($LASTEXITCODE -ne 0) { Write-Host "COMPILE FAIL: $Top"; exit 1 }

    $log = Join-Path $reg $LogName
    Write-Host "=== run $Top -> $LogName ==="
    & vvp $vvp | Tee-Object -FilePath $log

    $result = Select-String -Path $log -Pattern "^RESULT:\s*(\w+)" |
              ForEach-Object { $_.Matches[0].Groups[1].Value }
    if (-not $result) { Write-Host "RESULT not found: $Top"; exit 1 }
    if ($result -ne "PASS") { Write-Host "SIM FAIL: $Top ($result)"; exit 1 }
    Write-Host "[$Top] $result"
}

Invoke-Sim -Top "tb_copy_engine" `
    -Sources @((Join-Path $rtl "copy_engine.v"), (Join-Path $tb "tb_copy_engine.v")) `
    -LogName "rtl-engine-selftest.log"

Invoke-Sim -Top "tb_arbiter" `
    -Sources @((Join-Path $rtl "mem_write_arbiter.v"), (Join-Path $tb "tb_arbiter.v")) `
    -LogName "rtl-arbiter-selftest.log"

Invoke-Sim -Top "tb_path_loop" `
    -Sources @(
        (Join-Path $rtl "mem_ram_model.v"),
        (Join-Path $rtl "mem_write_arbiter.v"),
        (Join-Path $rtl "copy_engine.v"),
        (Join-Path $rtl "engine_mem_path.v"),
        (Join-Path $tb "tb_path_loop.v")
    ) `
    -LogName "rtl-path-loop.log"

Write-Host "ALL RTL SIM PASS"
