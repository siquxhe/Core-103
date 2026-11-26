# Core-103

一个做成微处理器形态的 103 机：对中国 103 机（苏联 M-3 仿制型，亦称八一型 / DJS-1）做 FPGA 软核复刻，在 iverilog 仿真环境下打通内核取指执行、外挂块拷贝引擎与共享 RAM 写仲裁的端到端闭环。

> 当前阶段为**软件仿真验证**：RTL 经 iverilog / vvp 功能仿真与回归，尚未综合上板，缺少 FPGA 工程与时序约束。

## 机器背景（源码核实口径）

| 维度 | 结论 |
|---|---|
| 数制 | 二进制定点；十进制 / 八进制仅出现在 I/O 界面层（BCD / 八进制打包） |
| 字长 | 31 位 = 1 符号位 + 30 位数值位；符号—数值码（非补码） |
| 定标 | 定点 1.30；乘 `(B·A)>>30`，除 `(B<<30)/A` |
| 架构 | 双地址内存—内存型；两条取数通路 A / B，B 寄存器留存结果 |
| 存储 | 2048 字 × 31 位，12 位扁平直接地址；无索引寄存器、无间接 / 自增寻址 |
| 控制 | 无中断、无栈、无栈指针、无 CALL/RET；I/O 全靠轮询握手 |

指令字格式：

```
[30] 符号 | [29:24] 操作码 6 bit | [23:12] c1 12 bit | [11:0] c2 12 bit
```

## 仓库结构

工程主体在 `c103-microprocessor/`：

| 路径 | 内容 |
|---|---|
| `c103-microprocessor/01..08-*.md` | 架构基线、可行性评估、演进路线、外设分层、固件方案、引擎设计与边界风险等调研文档 |
| `c103-microprocessor/work/rtl/` | 自研 RTL：拷贝引擎、写仲裁器、通路封装、行为 RAM 模型、命令块装配 |
| `c103-microprocessor/work/ip_core/core/` | 内核 RTL（运算器 / 操作器 / 脉冲分配 / 寄存器 / 存储 / IO 部件） |
| `c103-microprocessor/work/ip_core/shell/` | 面板脉冲、开关电平、74LV165 / 74LV595 驱动等外壳电路 |
| `c103-microprocessor/work/ip_core/tb/`、`work/tb_rtl/` | 集成 testbench 与 RTL 单元自检 testbench |
| `c103-microprocessor/work/engine/`、`work/tb/` | 拷贝引擎 C 行为模型、桥接模型与 C 测试驱动 |
| `c103-microprocessor/work/ip_core/test/` | 输入程序、任务序列与输出参考基线（MD5 比对） |
| `c103-microprocessor/work/docs/` | 分阶段接入进展与回归证据记录 |
| `c103-microprocessor/work/ip_core/run_*.ps1`、`work/rtl/run_rtl_sim.ps1` | 各档回归脚本 |

> 上游派生文件与自研文件的归属划分见根目录 [`NOTICE`](NOTICE)。

## 跨仓工作区布局

本工程由主仓与若干平级兄弟仓组成；全新克隆时需把它们放在同一个项目根目录下，回归脚本按此相对层级定位兄弟仓：

```
<项目根>/
├── Core-103/          # 主仓（本仓：RTL、内核副本、回归脚本、文档）
├── simulator/        # C 模拟器（machine_mem、103 解释器、err.h 兼容层）
├── tape-converter/    # 汇编 / 磁带转换与镜像打包器
├── test-program/      # 冻结测试程序与 MD5 参考基线
├── verify-verilator/  # Verilator 验证链路（src_hw 与 hardware 同源）
└── hardware/          # 上游现代硬件电路 Verilog 源
```

脚本中的相对回溯约定：

- `work/ip_core/run_loader_*.ps1`、`run_io_cases.ps1`：`$root` 从 `ip_core/` 向上四级回溯到项目根，再进平级兄弟仓。
- `tools/regress-image-loader.ps1`：`$root` 回溯到项目根，主仓内部路径补 `Core-103/` 层，兄弟仓仍在根下。
- `work/Makefile`：simulator 相对路径回溯三级到项目根。

> `test-program-gen/` 为生成物目录，不纳入版本控制。

## 已在仿真中闭环验证

- **内核指令子集**：加、减、按位与、乘、除、无条件跳转、条件跳转（正 / 负两路）、074 绝对值跳转，以及八进制 / 十进制 BCD 输入打包与输出解包。
- **块拷贝引擎**：7 态 FSM 块搬运；命令块（源 / 目的 / 长度 / GO / BUSY / DONE / ERR / ACK）装配与状态回写；桥模型 5-bit 符号流下发参数并等待 done 握手；核心固件子程序轮询 DONE 后写 ACK 完成握手。
- **共享 RAM 写仲裁**：CPU 通路与引擎子系统两路写主经时序仲裁器收敛到唯一写口；每主 4 深同步请求队列、round-robin 轮转防饥饿、授权互斥；并发搬运与 CPU 写不丢字、不饿死。
- **端到端**：引擎两段把程序与数据搬运到目的区后，核心从目的区取指执行，结果与参考基线一致。

核心端到端基线：`test/output.bin` MD5 `75af62902c598dd73cb654aa518d1a2b`，与参考一致。

## 快速开始

**依赖工具链**：PowerShell 7、iverilog / vvp（OSS CAD Suite）、w64devkit（gcc，C 模型与打包器编译）、Git（coreutils）。

回归脚本经公共片段 `tools/toolchain.ps1` 探测工具链：环境变量优先，未设置时回退常见安装路径（仅在目录实际存在时追加），不在脚本内硬编码某台机器的绝对位置。可用环境变量覆盖安装位置：

| 工具 | 环境变量 | 默认回退路径 |
|---|---|---|
| w64devkit | `W64DEVKIT_BIN` / `W64DEVKIT_HOME` | `C:\Program Files\w64devkit\bin` |
| OSS CAD Suite | `OSS_CAD_SUITE` | `C:\oss-cad-suite`（`bin`、`lib`） |
| Git usr/bin | `GIT_USR_BIN` | `C:\Program Files\Git\usr\bin` |

```powershell
# 核心端到端：直接执行冻结加法程序并比对 MD5
pwsh -File c103-microprocessor/work/ip_core/run_core_eb.ps1

# RTL 引擎 FSM + 写仲裁器自检（4 深队列 + 轮转防饥饿）
pwsh -File c103-microprocessor/work/rtl/run_rtl_sim.ps1
```

其余 `run_*.ps1` 分别覆盖引擎旁路集成、引擎搬运后核心执行、指令覆盖、减法 / 绝对值 / IO 用例、命令块握手、固件轮询、并发仲裁等场景；回归日志落在 `work/regress/`。

## 边界与未决项

- 传送变体（005 / 015 / 045 / 055 / 064）除端到端加法与 IO 路径外的组合尚未单独覆盖。
- 仲裁器 `stall`/`full` 已引出，满队队头保护、授权互斥与守恒已由单元仿真与形式验证覆盖；整链路 `core_top` 暂未把背压直通回写主侧（`wr_stall` 暂 tie 0），待整链路背压闭环。
- 拷贝引擎已按重叠关系自适应选向前向 / 反向：目的在源高侧且重叠时反向（高地址 → 低地址），其余情形正向（低地址 → 高地址）。
- 行为数组 RAM 与真实 S011 / BRAM 的一拍读延迟缓冲、片选与位掩码边界未复核；上板前需回接真实 RAM 模型或 Gowin BRAM 并补综合 / 约束。
- Flash / ROM 行为模型、块目录项（镜像 ID / 入口 / 字数 / 类型 / 校验和）为后续阶段。
- 指令集完整覆盖需对照原始《103 机程序汇编》或 RTL 译码表逐项核对。

## 许可与来源

本仓库以 **GPLv3** 许可发布，许可文本见 [`LICENSE`](LICENSE)。

工程在公开的 Computer-103 上游项目（hardware / verify-verilator / test-program）基础上二次开发；派生文件清单、修改范围与自研边界见 [`NOTICE`](NOTICE)。
