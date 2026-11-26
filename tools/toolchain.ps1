# 工具链 PATH 探测（纯环境变量驱动，可移植）
#
# 不在脚本里写死任何本机安装绝对路径。工具链位置只通过下列环境变量声明；
# 未设置对应变量时不主动追加，沿用当前系统 PATH（即工具已装入系统 PATH 的情况）：
#
#   W64DEVKIT_BIN   w64devkit 的 bin 目录（gcc 及其运行时）
#   W64DEVKIT_HOME  w64devkit 根目录（自动取其 bin 子目录）
#   OSS_CAD_SUITE   OSS CAD Suite 根目录（自动追加 bin 与 lib）
#   GIT_USR_BIN     Git usr/bin 目录（coreutils / diff 等）
#
# 用法：在回归脚本头部 dot-source 本文件后调用 Initialize-CoreToolchain。

function Initialize-CoreToolchain {
    $dirs = New-Object System.Collections.Generic.List[string]

    # ---- w64devkit（gcc / 运行时）----
    if ($env:W64DEVKIT_BIN) {
        $dirs.Add($env:W64DEVKIT_BIN)
    } elseif ($env:W64DEVKIT_HOME -and (Test-Path (Join-Path $env:W64DEVKIT_HOME "bin"))) {
        $dirs.Add((Join-Path $env:W64DEVKIT_HOME "bin"))
    }

    # ---- OSS CAD Suite（iverilog / vvp / yosys 等）----
    if ($env:OSS_CAD_SUITE) {
        if (Test-Path (Join-Path $env:OSS_CAD_SUITE "bin")) { $dirs.Add((Join-Path $env:OSS_CAD_SUITE "bin")) }
        if (Test-Path (Join-Path $env:OSS_CAD_SUITE "lib")) { $dirs.Add((Join-Path $env:OSS_CAD_SUITE "lib")) }
    }

    # ---- Git usr/bin（coreutils / diff）----
    if ($env:GIT_USR_BIN) {
        $dirs.Add($env:GIT_USR_BIN)
    }

    # 去重后前置到 PATH（不重复追加已在 PATH 中的目录）
    $existing = $env:PATH -split ';' | Where-Object { $_ }
    $prepend  = $dirs | Where-Object { $_ -and -not ($existing -contains $_) }
    if ($prepend) {
        $env:PATH = ($prepend -join ";") + ";" + $env:PATH
    }
}
