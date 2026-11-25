# 4m · #60 P0-1 RAM 读延迟模型与读缓冲回接 · 闭环复核

> 关联：`4b-P0-1引擎读通路同步BRAM改造记录.md`、`4e-P0-1路线甲落地-命令块剥离本地寄存器与回归综合复核.md`、`4g-引擎子系统装配综合与背靠背加压及dbg量产移除.md`、`3a-P0硬件落地前置项评估.md` §4、`4a-M3-103容量调研与BRAM改造方案.md` §7。
> 任务：#60「P0-1 回接真实 RAM 读延迟模型与读缓冲」。
> 口径：仿真 PASS 只覆盖激励路径；综合通过 ≠ 时序收敛；Fmax 为综合估算，无 SDC，真实时序以 P&R 为准。

## 1. 结论先行

#60 在**功能仿真 + 综合检查可达范围内已闭环**。行为数组主存已对齐「单写 + 双同步读」的同步 BRAM 模板，引擎读缓冲/等待拍已落地，完整装配（memory + engine_ctrl + copy_engine）双口连接下的 BSRAM 块数与读路径综合时序已复核，本轮复跑基线零回退、综合资源无漂移。

剩余两条本质属**上板 / L4 量产综合**范畴，移交 #86 跟进，不再阻塞 #60：

- 显例化 Gowin BSRAM 原语（当前为综合推断 BRAM，非原语例化）；
- P&R 后真实读路径时序与 Fmax（当前无开发板、无 SDC 约束）。

## 2. 调查三栏

### 2.1 事实（RTL / 文档第一手）

| 读通路 | 建模现状 | 证据位置 |
| --- | --- | --- |
| CPU 主读 | 同步一拍：`do_mem_read` 锁存地址 `addr_rd_r`，下一拍 `read_data_r <= mem[addr_rd_r]`，`read_finish_r=reading` 回 reply | `ip_core/core/memory.v` 123–188、209、216–220 |
| 引擎 eng 读口 | 同步一拍：`eng_rd_data_r <= mem[eng_rd_addr]`，输出经一级寄存器对齐 BRAM 延迟 | `memory.v` 223–228；独立通路模型 `rtl/mem_ram_model.v` 43、51–55 |
| 引擎 FSM 读缓冲 / 等拍 | 已含等待态 `ST_RD_WAIT`：FETCH 拍给源地址/读请求 → RD_WAIT 拍锁存 `rd_data` 到 `latch_word_r` → WRITE 落目的区；`rd_req` 在 FETCH/RD_WAIT 两拍保持 | `rtl/copy_engine.v` 65–71、112–114、186–195 |
| 命令块 ctrl 口 | 4e 路线甲剥离为 `engine_ctrl` 本地寄存器组 `cmd_q[0..7]`，组合读；FSM 全读 `local_rd_data = cmd_q[rd_idx]`，不再消费主存 `ctrl_rd_data` | `rtl/engine_ctrl.v` 121、149/156/162/168/205/236；`memory.v` 229 |
| dbg 调试口 | 正本保留组合直读（testbench 预填源区 / 直读校验夹具）；综合变体剥离归零，量产 wrapper tie 0 | `memory.v` 230；`regress/synth-engine/memory.v` 201–202、`engine_subsys_wrapper.v` 114–119 |

补充核对：

- 全量扫描正本 `*.v` 的数组直读：功能通路仅剩 `ctrl_rd_data` / `dbg_rd_data` 两处组合读；前者为未被 `engine_ctrl` 消费的兼容残留端口，后者为调试夹具口，均不参与功能数据通路。
- 综合变体形态：CPU 主读 + eng 旁路两个同步读口，ctrl/dbg 读不直读数组（输出归零），命令块写旁路保留。

### 2.2 推断

- #60 原始缺口（3a §4：旁路组合读、多端口行为数组不符同步 BRAM 模板；引擎按组合读节拍同拍锁存；未补读缓冲/等待拍）已在后续版本清偿：eng 同步读由 4b 落地，命令块本地寄存器由 4e 落地，完整装配综合复核由 4g 落地。
- 仿真侧当前无可改的读延迟 / 读缓冲缺口；正本 `ctrl_rd_data` 未消费端口属兼容分层口径（4e §6.1：正本行为模型保留调试/兼容通路，量产形态由变体剥离），不是 RTL 缺陷。

### 2.3 未知 / 待验（移交 #86）

- 完整装配在显例化 BSRAM 原语下的块数、位宽与位掩码口径，尚未定（3a/4a 既定留待上板阶段）。
- P&R 后真实读路径关键路径与 Fmax；本轮 55.404 MHz 为无 SDC 的综合估算。

## 3. 本轮复核证据

### 3.1 功能仿真回归（iverilog/vvp，正本工作区复跑）

| 套件 | 判据 / 结果 |
| --- | --- |
| engine-mem | `ENGINE-MEM INTEGRATION PASS` |
| engine-ctrl | `ENG-CTRL PASS` |
| fw-poll | `FW-POLL PASS` |
| move-cov | `MOVE-COV PASS` |
| cpu-eng-concur | `CPU-ENG CONCURRENCY PASS` |
| engine-core | `ENGINE-CORE E2E PASS` |
| core-eb（端到端） | output.bin MD5 `75af62902c598dd73cb654aa518d1a2b` = ref，PASS |
| loader-fw2（三段背靠背） | `LOADER-FW2 PASS` |

基线 MD5 与判据数与既有记录逐项对齐，无回退。

### 3.2 完整装配 Gowin 综合（本轮重跑，对齐当前正本 RTL）

顶层 `engine_subsys_wrapper`（memory 含仲裁器 + engine_ctrl + copy_engine，不挂内核 arith/IO/译码层），器件 `GW1NSR-LV4CQN48PC6/I5`，综合器 GowinSynthesis 1.9.11.03（Education），`exit 0`。

| 资源 | 数值 | 利用率 | 器件总量 |
| --- | ---: | ---: | ---: |
| BSRAM | **4** | 40% | 10 |
| FF（寄存器） | **816** | 23% | 3573 |
| LUT（LUT4） | **825**（logic_lut 890） | 20% | 4608 |
| ALU | 65 | — | — |
| Fmax（综合估算） | **55.404 MHz** | — | — |
| 逻辑级数 | 10 | — | — |

- 主存数组 `mem` 与仲裁双队列均被推断为存储单元；日志无 IF0008 / RP0001 / 多驱动 / 黑盒告警。
- 子模块归属（`*_syn_rsc.xml` 的 T_ 口径）：u_mem BSRAM 4 / FF 402 / LUT 228；u_wr_arb FF 357 / LUT 203；u_eng FF 111 / LUT 156；u_ctrl FF 303 / LUT 441。
- 本轮重跑数值与 4g §1.2 记录逐项一致，当前正本 RTL 综合资源无时序漂移。

> 口径提醒：本 wrapper 为引擎子系统口径，与 `synth-converged` 整核 `core_top` 基线（ff 598 / lut 785 / bsram 8 / 64.452 MHz）资源构成不同，不可直接相减混比。

## 4. 开放项与移交

| 项 | 现状 | 归属 |
| --- | --- | --- |
| 显例化 Gowin BSRAM 原语（位宽 / 字节使能 / 单双口口径） | 行为数组 + 综合推断 BRAM；未例化原语 | #86 / 上板阶段 |
| P&R 后读路径真实时序、Fmax | 无板、无 SDC；综合估算 55.404 MHz | #86 / 上板阶段 |
| 量产形态命令块由装载器还是固件驱动 | wrapper 已预留命令写入口，系统层未定型 | 4g §六，L3 装载路线跟进 |

## 5. 脉络对照（避免回退旧判断）

- 3a §4 记录的「引擎按组合读同拍锁存、未补等待拍」为早期状态；`copy_engine.v` 现含 `ST_RD_WAIT`，该旧债已清偿。
- 4b §遗留「ctrl/dbg 口同步读化未闭环」已由 4e（ctrl 剥离本地寄存器）与 4g（dbg 量产剥离）分别收口。
- 4e §6.2「完整装配 wrapper 综合待补」已由 4g 落地，本轮重跑复核无漂移。
