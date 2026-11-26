# 工具链 PATH 探测（可移植回退）
#
# 设计：环境变量优先；未设置时回退到常见安装路径，且仅在目录实际存在时追加。
# 不在脚本里硬编码某一台机器的绝对安装位置；换机器 / 换目录时，要么把工具
# 装进默认路径，要么用下列环境变量覆盖对应 bin：
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
    } elseif (Test-Path "C:\Program Files\w64devkit\bin") {
        $dirs.Add("C:\Program Files\w64devkit\bin")
    } elseif (Test-Path "C:\w64devkit\bin") {
        $dirs.Add("C:\w64devkit\bin")
    }

    # ---- OSS CAD Suite（iverilog / vvp / yosys 等）----
    $oss = $env:OSS_CAD_SUITE
    if (-not $oss -and (Test-Path "C:\oss-cad-suite")) { $oss = "C:\oss-cad-suite" }
    if ($oss) {
        if (Test-Path (Join-Path $oss "bin")) { $dirs.Add((Join-Path $oss "bin")) }
        if (Test-Path (Join-Path $oss "lib")) { $dirs.Add((Join-Path $oss "lib")) }
    }

    # ---- Git usr/bin（coreutils / diff）----
    if ($env:GIT_USR_BIN) {
        $dirs.Add($env:GIT_USR_BIN)
    } elseif (Test-Path "C:\Program Files\Git\usr\bin") {
        $dirs.Add("C:\Program Files\Git\usr\bin")
    } elseif (Test-Path "C:\Program Files (x86)\Git\usr\bin") {
        $dirs.Add("C:\Program Files (x86)\Git\usr\bin")
    }

    # 去重后前置到 PATH（不重复追加已在 PATH 中的目录）
    $existing = $env:PATH -split ';' | Where-Object { $_ }
    $prepend  = $dirs | Where-Object { $_ -and -not ($existing -contains $_) }
    if ($prepend) {
        $env:PATH = ($prepend -join ";") + ";" + $env:PATH
    }
}
