# 4b · P0-1 引擎读通路同步 BRAM 改造记录

> 关联：`4a-M3-103容量调研与BRAM改造方案.md` §7（端口收敛 / 读延迟对齐 / 分阶段落地）。
> 口径：仿真 PASS 只覆盖已激励路径；BRAM 块数/档位以 Gowin 综合报告 `*_syn_rsc.xml` 为准。

## 1. 目标与本轮范围

P0-1（#60）：把行为数组主存从"组合读"向"可被 BRAM 推断的同步读模型 + 引擎读缓冲/等拍"对齐，同时保持既有 iverilog 回归零回退。

本轮只落地**引擎读通路**的同步读改造；ctrl / dbg 配置调试口按 4a §7.2 保留组合读，留待端口收敛阶段以 LUTRAM / 寄存器兜底。

## 2. 落地改动

| 文件 | 改动 | 读时序口径 |
| --- | --- | --- |
| `rtl/mem_ram_model.v` | 功能读口改同步读：新增 `rd_data_r`，每拍 `rd_data_r <= mem[rd_addr]`，下一拍输出；dbg 调试口保持组合读 | 同步 BRAM 一拍延迟 |
| `rtl/copy_engine.v` | 新增等待态 `ST_RD_WAIT=3'd7`：`ST_FETCH` 只发地址/读请求并进等待拍，`ST_RD_WAIT` 拍锁存 `rd_data` 再进 `ST_WRITE`；`rd_req` 在 FETCH/RD_WAIT 两拍保持 | 地址拍给地址，下一拍采样 |
| `ip_core/rtl/copy_engine.v` | 上一份的内核集成副本，内容与 `rtl/copy_engine.v` 一致 | 同上 |
| `tb_rtl/tb_copy_engine.v` | 内置 RAM 模型改同步读（一级 `rd_data_r` 寄存器），对齐引擎等拍假设 | 同步读 |
| `ip_core/core/memory.v` | 引擎旁路读口新增 `eng_rd_data_r` 同步锁存；`ctrl_rd_data` / `dbg_rd_data` 保留组合直读 | 仅 eng 口同步读 |

未改动：`rtl/engine_ctrl.v`（原版紧凑 FSM）、CPU 主读写路径、写仲裁器、背压 FIFO。

## 3. 二分定位过程与结论

改造中内核链 `fw_poll`（多轮搬运 + 固件轮询用例）出现回退：第二轮常量段目的区读到 `x`，引擎停在 `ST_DONE`、DONE 镜像残留。逐级隔离：

- **隔离 A**：eng 旁路组合读、ctrl 旁路同步读 → `fw_poll` 仍 FAIL。
- **隔离 B**：eng/ctrl 旁路全组合读、仅保留新 FSM → `fw_poll` PASS。
- **隔离 C**：仅 eng 旁路同步读、ctrl/dbg 组合读 → 引擎套件与 `fw_poll` 全 PASS。

定位结论：

1. **引擎读通路（eng 口）同步读与引擎 FSM 等拍对齐成立**，可保留。
2. **ctrl 旁路同步读触发多轮时序回归**：观测到命令块参数严格滞后一轮（第二轮读到第一轮 SRC/DST/LEN）。ctrl 口是命令块配置/状态镜像口，容量小、访问不频繁，按 4a §7.2 归入 LUTRAM / 寄存器兜底，本轮不挂同步 BRAM 读口。
3. 曾尝试把 ctrl 读地址由寄存器改为状态组合译码以消除"地址寄存器 + 输出寄存器"两级滞后，实测未消除回归；该方案否证，未保留。

## 4. 回归证据（全量绿，零回退）

工具链：iverilog/vvp 14.0（OSS CAD Suite）；PATH 前置 `Git usr/bin / w64devkit / oss-cad-suite`。

### 4.1 独立通路三档（`rtl/run_rtl_sim.ps1`）

| 用例 | 结果 |
| --- | --- |
| tb_copy_engine | PASS |
| tb_arbiter | PASS |
| tb_path_loop | PASS（32 判据，0 失败） |

### 4.2 内核集成九套（`ip_core/run_*.ps1`）

| 套件 | 判据数 | 结果 |
| --- | --- | --- |
| engine-mem | 17 | PASS |
| engine-ctrl | 12 | PASS |
| fw-poll | 18 | PASS |
| inst-cov | 10 | PASS |
| move-cov | 5 | PASS |
| sub | 14 | PASS |
| abs | 4 | PASS |
| cpu-eng concur | 20 | PASS |
| engine-core | 2 | PASS |

### 4.3 基线 MD5（不可回退）

| 基线 | MD5 | 结果 |
| --- | --- | --- |
| core-eb `output.bin` | `75af62902c598dd73cb654aa518d1a2b` | 与 ref 一致 |
| 01_io | `67146a4fa9da8dfa0c01dbb5fb21e994` | PASS |
| 01_io2 | `843b2c87e004d8c18c8b43b6ebed6ceb` | PASS |
| 01_io3 | `1437c3c3d04b76d0535baa23da09f9ab` | PASS |

## 5. 遗留与下一步

1. **ctrl / dbg 口同步读化未闭环**：命令块配置/状态口后续按端口收敛方案走 LUTRAM 或寄存器堆；若要挂 BRAM 同步读口，需先实测模型读延迟拍数，再配 FSM 等待拍（当前紧凑 FSM 按组合读同拍取数）。
2. **端口收敛（4a §7.2 核心难点）**：现状四读口 + 两写主无法直挂单块 BRAM；写口已由 `mem_write_arbiter` 收敛单写口，读口分时复用 / 双口器件映射待阶段 2 落地。
3. **Gowin BRAM 原语复核**：原语端口名、宽深档位、单/双口类型需查原语手册或综合网表确认；综合阶段观察 BSRAM 计数是否从 63488 DFF 阵列转为块 RAM。
4. `regress-test-program.ps1` 的 21 例 C 模拟器回归结果仍只走控制台、未落日志（沿用 3b §3 备注）。

## 6. 本次未提交项说明

正本改动先同步进 Core-103 仓内副本；commit / push 为外部写操作，待显式确认后执行。`engine_ctrl.v` 与基线一致，未纳入本轮改动集。
