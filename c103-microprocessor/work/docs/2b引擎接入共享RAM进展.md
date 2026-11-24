# 2b 进展：拷贝引擎接入共享 RAM · 端到端闭环

> 日期：2026-11-24 ｜ 阶段：第二步 2b（引擎读写口接入既有存储通路，串联核心执行）
> 产物目录：`c103-microprocessor/work/`（本阶段全部新增产出均在此目录下；既有四个 git 仓库原位未改）。

## 1. 现状结论

- **2a（已完成）**：核心在独立 iverilog 工程直接执行 `07_add1` 冻结程序，`output.bin` MD5 与参考一致。
- **2b（已闭环）**：引擎读写口接入与核心共享的行为数组 RAM；最小加法程序经引擎两段搬运到目的区后，**核心从目的区 0000 取指执行，结果校验正确**（端到端 PASS）。
- 已验证命题：引擎搬运落位正确；引擎写入与核心读取同一存储数组；核心可执行引擎装入目的区的代码。

## 2. 本轮完成增量与证据

### 2.1 行为数组 RAM 等价替换

- **改动文件**：`work/ip_core/core/memory.v`；S011 原始实现备份为同目录 `memory_s011.v.orig`（非 `.v`，不参与编译）。
- **实现**：内部改为扁平 `reg [30:0] mem [0:WORDS-1]`（`WORDS=2048`）；读 / 写各一拍，reply 沿用原 `read_finish_r` / `write_finish_r` 语义；新增引擎旁路 `eng_rd_*/eng_wr_*` 与调试口 `dbg_*`。
- **等价性回归**：`run_core_eb.ps1` 重跑，`output.bin` MD5 `75af62902c598dd73cb654aa518d1a2b`，与 ref 一致（`regress/core-eb.log`）。

### 2.2 引擎旁路 ↔ 共享 RAM 可见性集成

- **DUT**：`memory` + `copy_engine #(.MEM_SIZE(2048))`；testbench `work/ip_core/tb/tb_engine_mem.v`。
- **场景**：调试口预填源区 100 起 8 字 → 引擎搬到目的区 300 起 → 调试口逐字回读比对；源区未改写。
- **结果**：16 判据 PASS / 0 FAIL（`regress/engine-mem.log`）；回归脚本 `run_engine_mem.ps1`。

### 2.3 端到端：核心执行目的区装入程序

- **顶层透传**：`core_top` 引出 memory 的 `eng_*` / `dbg_*` 端口并直通内部 `u_memory`（`work/ip_core/core/core_top.v`）。
- **DUT**：`core_top` + `copy_engine`；testbench `work/ip_core/tb/tb_engine_core.v`；回归脚本 `run_engine_core.ps1`。
- **最小加法程序**（目的区布局，八进制地址）：

  | 地址 | 指令 | 语义 |
  |---|---|---|
  | 0000 | `+00 3000 3001` | `mem[3001] = mem[3000] + mem[3001]` |
  | 0001 | `+05 3001 3002` | `mem[3002] = mem[3001]`（传送） |
  | 0002 | `+54 0000 0000` | 停机 |

  数据：`3000=3, 3001=4, 3002=0`。

- **流程**：调试口预填源区（程序段 `1000` 起、数据段 `1500` 起）→ 引擎两段搬运（程序→`0000`，数据→`3000`）→ `arr_strt` 预置入口 `0000` → `clear_pu` + `start_pulse` 启动 → 停机后调试口读结果。
- **结果**：`mem[3001]=7`、`mem[3002]=7`，PASS=2 / FAIL=0，`ENGINE-CORE E2E PASS`（`regress/engine-core.log`）。

### 2.4 指令覆盖扩充（引擎搬运后核心目的区执行）

- **DUT / testbench**：`core_top` + `copy_engine`；`work/ip_core/tb/tb_inst_cov.v`；回归脚本 `run_inst_cov.ps1`；日志 `regress/inst-cov.log`。复用 2b 装载链路：调试口预填源区 → 引擎两段搬运 → 启动取指 → 停机后调试口回读判据。
- **定点 1.30**：值 = 尾数 / 2^30；乘 `(b*a)>>30`，除 `(b<<30)/a`（对齐 `103.c` `do_mul/do_div`）。
- **10 判据全 PASS / 0 FAIL**：

  | 用例 | 指令（op） | 输入 | 预期结果（mem） |
  |---|---|---|---|
  | 位与 AND | `+06 3000 3001` | 15 & 6 | 3001=6，3002=6 |
  | 无条件跳转 BR | `+24 0002 2000` | 42 | 跳过 0001；3001=0，3002=42 |
  | 乘法 MUL | `+03 3000 3001` | 1/2 × 1/2 | 3001=3002=2^28（1/4，`0x10000000`） |
  | 除法 DIV | `+02 3000 3001` | (1/4) ÷ (1/2) | 3001=3002=2^29（1/2，`0x20000000`） |
  | 条件跳转·正 | `+34 0003 0002` | b 非负 → c2 | 3002=42 |
  | 条件跳转·负 | `+34 0003 0002` | b 为负 → c1=0003 停机 | 3002=0（未写） |

- **条件跳转 RTL 时序核实**（`operator.v` / `pulse_unit.v`）：pulse3 先把 c1 载入启动寄存器；b 非负时 pulse7 再用 c2 覆盖（`ctrl_select_to_start_at_7 = p2==4 && p1[1] && p1[0] && ~b_sign`），b 为负则保持 c1。与 C 语义（符号位 1→c1，否则 c2）一致。
- **RTL 乘除实现**（`arith_ctrl.v`）：无独立乘除器，`mul_state`/`div_state` 配合 29 拍计数器（`counter_finish_mul_div`）做移位累加 / 移位恢复序列；与、加、减在 `arith_unit` 内组合完成。

### 2.5 命令块契约与装配模块 engine_ctrl

- **背景**：此前引擎命令由 testbench 直驱 `cmd_src/dst/len/go`，真实链路无控制面入口。本轮在共享 RAM 内划定固定命令块（八进制地址，31 位字，低 12 位放参数 / 标志），由新增装配模块 `work/rtl/engine_ctrl.v` 取参、锁存引擎寄存器、回写状态镜像。

  | 地址 | 符号 | 含义 |
  |---|---|---|
  | `2400` | CMD_SRC | 源地址 |
  | `2401` | CMD_DST | 目的地址 |
  | `2402` | CMD_LEN | 搬运字数 |
  | `2403` | CMD_GO | 非 0 启动；装配后自清 |
  | `2404` | STS_BUSY | 状态镜像：1=搬运中 |
  | `2405` | STS_DONE | 状态镜像：1=完成 |
  | `2406` | STS_ERR | bit0=err，bit[2:1]=err_code |
  | `2407` | CMD_ACK | 1=ack_done / 2=ack_err；装配后自清 |

- **RAM 旁路**：`memory.v` 新增 `ctrl_rd_*`（组合读）/ `ctrl_wr_*`（同步写）旁路，与 `eng_*` 同构；`core_top.v` 直通引出。
- **装配 FSM**：`S_IDLE → S_LD_SRC → S_LD_DST → S_LD_LEN → S_ARMED → S_DONE / S_ERR → S_IDLE`。LD_LEN 拍锁存 SRC/DST/LEN、自清 GO 并发 `cmd_go` 脉冲；ARMED 幂等回写 BUSY；DONE 态依次清 BUSY、置 DONE、等 ACK；ERR 态同构回写 ERR 字；收到 ACK 后向引擎发 `ack_done/ack_err`、清 ACK、回 IDLE。
- **状态镜像残留（已在 2.9 清理）**：早期版本 DONE/ERR 态 ack 后只清 ACK 字即回 IDLE，STS_DONE / STS_ERR 镜像残留到下一轮；现已补末拍清零。

### 2.6 桥模型层：5-bit 符号流下发参数 + wait done 握手

- **DUT / testbench**：`core_top` + `copy_engine` + `engine_ctrl`；`work/ip_core/tb/tb_engine_ctrl.v`；回归脚本 `run_engine_ctrl.ps1`；日志 `regress/engine-ctrl.log`。
- **下发链路**：复用既有 5-bit 纸带符号流（`NUM0..7` / `SEL@` / `POS+` / `WRITE 换行`），经 `io_unit → arith_ctrl` 移位打包写入命令块：先分三块写 SRC/DST/LEN 并读回校验，再单独写 GO（避免 GO 写入后 ctrl 当拍采样自清、读回判 1 失败）。
- **握手**：桥模型轮询 STS_DONE 镜像，完成后校验目的段落位；BUSY 置位作为观测信息（窗口短，不计入 fail）。
- **结果**：10 判据 PASS / 0 FAIL，`saw_busy=1`，目的区落位 `3 4 5`，`ENG-CTRL E2E PASS`。

### 2.7 核心固件层：子程序读状态块循环等待 done 后写 ACK

- **DUT / testbench**：同上三模块；`work/ip_core/tb/tb_fw_poll.v`；回归脚本 `run_fw_poll.ps1`；日志 `regress/fw-poll.log`。
- **分层复位**：testbench 把复位拆为两路——`sys_resetn`（引擎 / ctrl，初始一次后保持）与 `core_resetn`（核心 PU/IO）。固件装入后、启动前只脉冲 `core_resetn` 清纸带残留，**不打断引擎在 DONE 态等待 ACK**；memory 复位不清数组，固件与常量保留。
- **固件子程序**（目的区八进制地址；定点 1.30，阈值常量 `2001=1` 尾数 1，使 `1-1=0` 非负、`0-1=-1` 为负）：

  | 地址 | 指令 | 语义 |
  |---|---|---|
  | `0000` | `+05 2405 2000` | `reg_c = mem[DONE]`，暂存 `2000` |
  | `0001` | `+01 2001 2000` | `c = b(2000) − a(2001=1)`，存 `2000` |
  | `0002` | `+05 2000 2002` | 差值 c→b，暂存 `2002` |
  | `0003` | `+34 0000 0005` | b 为负（未完成）→ 回 `0000` 循环；非负（完成）→ `0005` |
  | `0005` | `+05 2001 2407` | `mem[ACK] = 1`（非 0 即握手） |
  | `0006` | `+54 0000 0000` | 停机 |

- **判支依据**：103 无零标志 / 比较指令，仅符号位可判；用减法造正负差，结果经传送 `c→b` 后交 `034` 条件跳转按 `reg_b` 符号判支（减法语义 `res = b − a`，对齐 `103.c do_sub`）。
- **闭环证据**：核心停机后引擎回 IDLE、ACK 被消费自清；6 判据 PASS / 0 FAIL，`FW-POLL E2E PASS`。
- **本轮修复的 RTL 竞态**：ctrl 在 ack 分支回 IDLE 的首拍，读地址寄存器仍停在 ACK，且 ACK 清零写有一拍延迟，IDLE 段误把 ACK 残留当成 GO 非 0，触发一次二次搬运。修复：ack 分支回 IDLE 的同时把 `rd_addr_r` 切回 `ADDR_GO`（DONE / ERR 两路同构处理）。

### 2.8 指令覆盖补齐：减法 / 074 绝对值跳转 / 十进制 BCD

- **减法（op=01）**：testbench `work/ip_core/tb/tb_sub.v`，脚本 `run_sub.ps1`，日志 `regress/sub-cov.log`。对齐 `103.c do_sub`：`res = sign_b*num_b − sign_a*num_a`，结果存回 c2；`res>0` 尾数正，`res<0` 置 bit30 负号，`res==0` 符号取 `sign_b`。7 个符号组合用例、14 判据全 PASS：

  | 用例 | a | b | 预期 res |
  |---|---|---|---|
  | S1 正−正 | +3 | +5 | +2 |
  | S2 正−正得负 | +5 | +3 | −2 |
  | S3 负−正 | −3 | +5 | +8 |
  | S4 正−负 | +5 | −3 | −8 |
  | S5 负−负 | −5 | −3 | +2 |
  | S6 零结果（b 正） | +4 | +4 | 正 0 |
  | S7 零结果（b 负） | −4 | −4 | 负号 + 0 |

- **074 绝对值跳转**：testbench `work/ip_core/tb/tb_abs.v`，脚本 `run_abs.ps1`，日志 `regress/abs-cov.log`。对齐 `103.c` line149：`reg_pc = c2`（无条件跳第二地址），`reg_b &= 0x3fffffff`（清 b 符号位、尾数保留），不读写内存。用 074 之后的 `034` 条件跳转反推 b 符号：074 清符号后 b 非负，034 走 c2；同时 c1 指向被跳过的写标记指令，验证确实跳的是 c2。2 用例、4 判据全 PASS（负 b 取绝对值、正 b 保持正号）。
  - RTL 通路核实：`operator.v` `ctrl_abs_to_ac = p1[2] && p1[0]`；`arith_ctrl.v` 在 `move_c_to_a/b`、`move_b_to_c` 时按 `!ctrl_abs` 屏蔽符号位；`start_pulse_to_io` 显式包含 `op==6'o74`。

- **十进制 BCD 打包 / 解包**：复用 `tb_core_eb` 纸带链路（`sim_input` 读 `test/input.bin`、`sim_output` 写 `test/output.bin`，`task.seq` 驱动面板开关）；脚本 `work/ip_core/run_io_cases.ps1` 从冻结 `test-program/<case>` 铺纸带与参考输出，跑完自动恢复既有 core-eb 基线。三用例 `output.bin` MD5 与 C 模拟器冻结参考逐一匹配：

  | 用例 | 链路 | 参考 MD5 |
  |---|---|---|
  | `01_io` | 八进制双向回环 | `67146a4fa9da8dfa0c01dbb5fb21e994` |
  | `01_io2` | 十进制 BCD 双向回环（`-d -D`，128 个 7 位带符号数） | `843b2c87e004d8c18c8b43b6ebed6ceb` |
  | `01_io3` | 输出后停机（`-S`） | `1437c3c3d04b76d0535baa23da09f9ab` |

  - 十进制 oracle 规则（`103.c do_input/do_output_reg_c`）：每位 4 bit；BCD 占 `bit29..2`（7 位 ×4=28 bit，低 2 位留空，WRITE 时 `reg_c <<= 2` 左对齐）；负号置 bit30；输出从 `bit26` 起每 4 bit 取一位。RTL `io_unit` 的 `shift_4_bit` / dec 态机 / 4-bit 输出分支与该位序一致，端到端无差异。

### 2.9 写仲裁实接集成链路 + ctrl 状态镜像残留清理

**写仲裁实接**

- **改动前缺口**：集成链路 `memory.v` 有三个功能写主——CPU 数据通路写、拷贝引擎搬运写、`engine_ctrl` 状态镜像写——各自 `if(req) mem[addr]<=data` 直写同一数组；`mem_write_arbiter` 只在独立闭环 `engine_mem_path` 内例化，集成 RAM 链路并未经过仲裁。
- **本轮接法**（`work/ip_core/core/memory.v`）：
  - CPU 写主取 `writing` 拍已锁存的 `addr_r / write_data_r`；引擎子系统写主合并 `copy_engine` 搬运写与 `engine_ctrl` 状态镜像写（同拍冲突时搬运写优先，ctrl 幂等状态写顺延一拍）。
  - 两路经 `mem_write_arbiter u_wr_arb` 二选一收敛到唯一功能写口落数组；`dbg` 调试写旁路保留（复位 / 预填期使用）。`core_top` 透传 `grant_cpu / grant_eng / arb_conflict` 观测口。
  - **悬空归一化**：旁路未接的 testbench 中端口为 `z`，`eng_active / ctrl_active` 用 `=== 1'b1` 判 1，把 `z/x` 视为 0；否则不确定电平经地址 / 数据组合 mux 传入仲裁器，会把 CPU 授权拉成 `z` 阻断 CPU 写（本轮实测复现并定位）。
- **本阶段仲裁约定（2.9 初版，已由 2.10 公平仲裁取代）**：当时为非并发二选一——装载期核心停住、引擎优先占写口；双方同拍请求时 `conflict=1`、授权归引擎，CPU 请求在引擎占用期被阻塞。请求挂起 / 保持 / 公平轮转在 2.10 落地。
- **证据**：`regress/engine-mem.log` 17 判据 PASS / 0 FAIL（含整段搬运全程 `arb_conflict=0` 观测）；独立 `rtl-path-loop` 32 判据仍 PASS。

**ctrl 状态镜像残留清理**（`work/rtl/engine_ctrl.v`）

- **改动前问题**：`S_DONE / S_ERR` 收到 ACK 后，当拍发 `ack_done/ack_err` 脉冲、清 ACK 字即回 IDLE，STS_DONE / STS_ERR 镜像未清，残留到下一轮启动。
- **本轮时序**：收尾分两拍——phase2 收到 ACK 发握手脉冲并清 ACK 字，转 phase3；phase3 再清 DONE / ERR 镜像，然后切读地址回 `ADDR_GO`、回 IDLE。命令块 BUSY / DONE / ERR / ACK 四个字在握手后全部回到干净态。
- **证据**：`regress/engine-ctrl.log` 12 判据 PASS / 0 FAIL（握手后回读 DONE、ERR 镜像均为 0）；`regress/fw-poll.log` 7 判据 PASS / 0 FAIL（握手后 DONE 镜像为 0、引擎回 IDLE、ACK 自清）。

### 2.10 并发公平仲裁：请求挂起 / 保持 / 轮转防饥饿

**改造前缺口**：2.9 落地的 `mem_write_arbiter` 为纯组合二选一——`grant_eng=eng_req`，`grant_cpu=cpu_req & ~eng_req`，无请求锁存、无保持、无轮转。两个写主（CPU 通路、拷贝引擎 FSM）当前都是**单拍请求、无反压**：CPU `writing` 单拍、引擎 WRITE 态只停留一拍即推进。纯组合仲裁下未授权请求下一拍即消失，并发同拍时丢写；旧约定靠"装载期核心停住、引擎独占"规避并发，未做真正的公平排队。

**本轮实现（时序仲裁器 + 请求保持 + 轮转）**

- **改动文件**：
  - `work/rtl/mem_write_arbiter.v`：重写为时序版，新增 `clk / resetn`；每主一个单 entry 待写锁存（`cpu_pending / eng_pending` 及配套 `addr_r / data_r`）。
  - `work/ip_core/core/memory.v`：CPU 写 reply 改为跟随授权拍；仲裁器例化补 `clk / resetn`。
  - `work/rtl/engine_mem_path.v`：独立闭环仲裁器例化补 `clk / resetn`。
- **请求保持**：请求拍把 `addr / data` 锁存进 pending；未授权前一直保持，**不依赖外部请求电平持续**（适配单拍脉冲的 FSM）；授权拍消费当前待写，同拍若有新请求则接力锁存。
- **公平轮转（round-robin）**：单主待写直通；双主双待写时按 `last_eng` 记录轮转——上轮授权方本轮让位给另一方，避免一方被连续突发饿死。授权唯一（`grant_cpu / grant_eng` 互斥），RAM 单写口不会双写。`conflict` 仅作双主同时待写的观测指示。
- **CPU reply 跟随授权拍**：`write_finish_r <= grant_cpu`（旧版固定 `<= writing`）。CPU 写被引擎抢占挂起期间，reply 一并推迟，待真正落数组后一拍回送。上层 `io_unit` 写态（`IN_WRITE`）与 PU 状态机本就阻塞等 `mem_write_reply`，推迟 reply 对其透明，不会提前推进导致丢字；本轮未改动 PU / IO 握手链路本身。
- **范围边界**：本轮在仲裁器 / memory 写口层做排队与保持，未改 `copy_engine` FSM；引擎子系统写主仍合并拷贝搬运与 ctrl 状态镜像（搬运优先）。初版为单 entry 缓冲；多字深排队的背压 FIFO 已在 2.11 落地。

**自检与证据**

- **仲裁器穷举自检**：`work/tb_rtl/tb_arbiter.v`（初版判据与最新 FIFO 版判据见 2.11 证据清单）：
  - A1/A2 单主直通，写口透传对应主地址 / 数据，服务后撤销；
  - A3 双方持续双待，轮转交替 `eng → cpu → eng`，不固定引擎优先，`conflict` 置位；
  - A4 双方均无，无授权 / 无冲突 / 无写使能；
  - A5 CPU 单拍请求被引擎抢占，pending 挂起保持、轮转让位后最终服务，不丢写；
  - A6 挂起期数据隔离：CPU 待写 `addr / data` 不被引擎数据污染，服务拍回送 CPU 锁存值。
- **并发端到端集成自检**：`work/ip_core/tb/tb_cpu_eng_concur.v`，脚本 `run_cpu_eng_concur.ps1`，日志 `regress/cpu-eng-concur.log`，20 判据 PASS / 0 FAIL：引擎搬运 8 字进行中并发发起 3 个 CPU 写至独立地址区；校验目的区逐字落位（引擎搬运未被干扰）、3 个 CPU 写全部落数组（未饿死、未丢字）、源区未改写、全程无双授权。
- **无回退**：RTL 三档（引擎 FSM 39 / 仲裁器 51 / 通路闭环 32）与全部集成回归（核心端到端 MD5 `75af6290…`、engine-mem 17、engine-ctrl 12、fw-poll 7、engine-core 2、inst-cov 10、sub 14、abs 4、IO 三例 MD5、并发仲裁 20）全部 PASS / 0 FAIL。

### 2.11 写主侧背压 FIFO：单 entry 扩为 4 深请求队列

**改造前缺口**：2.10 初版仲裁器每主仅单 entry 待写锁存——待写未排空时，跨拍新请求既进不了锁存分支、也未在非授权拍接力，会被丢弃；单 entry 只能吸收一拍排队，无法承载连续背靠背写。

**本轮实现**（`work/rtl/mem_write_arbiter.v`，内联两主队列，未新增子模块以免改动一串显式编译清单）：

- **队列结构**：每主一个 `FIFO_DEPTH=4` 深同步请求队列，条目打包 `{addr[11:0], data[30:0]}`；独立写指针 `wp` / 读指针 `rp`（多 1 位判空 / 满）。请求拍入队排队，仲裁取队头授权，先进先出顺序出队。
- **入队 / 出队**：`req && !full` 写队列并推进 `wp`；授权拍且队列非空推进 `rp`。入队与出队可同拍流水线，指针独立加减。
- **背压标志**：`cpu_full / eng_full` 引出为观测 / 背压指示；满队时新请求不入队（背压点），队头不被覆盖。当前写主侧尚无 stall 输入接回，满队路径为预留反压接口。
- **保持既有公平性**：轮转 `last_eng`、授权互斥、`conflict` 观测语义不变；队列非空即有待写，双非空按上轮授权方让位轮转。

**自检与证据**（`work/tb_rtl/tb_arbiter.v`，日志 `rtl-arbiter-selftest.log`，51 判据 PASS / 0 FAIL）：

- A1/A2 单主直通；A3 双待轮转 `eng→cpu→eng`；A4 排空后空闲无残留；
- B1 CPU 连续 4 条背靠背入队，FIFO 顺序出队，地址 / 数据逐条匹配，4 条全部排空；
- B2 双主各 3 条交错入队，轮转出队，双方条目全部出完、不饿死，各自顺序正确；
- B3 空队时 `full` 标志为 0。
- **未覆盖分支**：满队（`full=1`）状态下"新请求丢弃且队头不被覆盖"的定向激励本轮未触发——双主轮转交替下单主难以堆积到 4 深；该路径待后续把 `full` 接回写主侧 stall 反压时补定向用例。

## 3. 关键事实（源码核实 + 本轮实测）

### 3.1 指令字编码

- 字长 31 位：`bit30` 符号，`bit29..24` op6，`bit23..12` c1，`bit11..0` c2。
- 译码（对齐 `simulator/src_c/103.c` 与 RTL `operator.v`）：`op=(word>>24)&6'h3f`，`c1=(word>>12)&12'hfff`，`c2=word&12'hfff`。
- 指令字构造：`{1'b0, op[5:0], c1[11:0], c2[11:0]}`；实测与 RTL 译码吻合。
- 停机指令：`op=054`（C 模拟器 `reg_op==054` 为 break 分支）。
- 算术 op2：0 加、1 减、2 除、3 乘、6 与；op1 高 3 位区分存取 / 输出 / 取数辅助特征。

### 3.2 核心启动喂入条件（本轮定位）

- PU（`pulse_unit`）状态机在 state 2 / 4 / 6 推进需要 `start_pulse_from_io` 再次喂入；面板手动 `start_pulse_from_pnl` 仅在 state0 一次性有效。
- 运行期须置 `automatic=1`：此时 `start_pulse_to_pu` 由 `start_pulse_auto`（`start_pulse_r` / 输出完成脉冲）自动喂入各等待态。**漏置 automatic 会使 PU 卡在 state2**（本轮实测卡点）。
- 入口寄存器 `start_reg`：`do_arr_strt` 拍把 `arr_strt_value` 打入 `strt`；`clear_pu` 清 PU，`start_pulse` 启动取指。

### 3.3 07_add1 内存布局（`input.103` 文本镜像）

- 数据区 `3000..3777`（512 字，成对 x/y）；程序区 `0000..1177`；`2010/2011` 输出缓冲，`2000` 暂存；入口 `0000`。

### 3.4 为何替换存储模型

- 既有 S011 器件模型把 RAM 数组封装在模型内部，外部 testbench / 引擎不可直连，也无法旁路预填或校验落位。
- 2b 在工程副本内用可见数组行为模型替换；S011 原实现备查于 `memory_s011.v.orig`。既有 `verify-verilator` / `hardware` 仓库原位未改。

## 4. 接口与时序约束（沿用 RTL 引擎契约）

- 引擎读口按组合读假设：FETCH 态给出 `rd_addr/rd_req`，当拍 `rd_data` 有效；行为 RAM 旁路 `eng_rd_data` 为组合读，与之匹配。
- 引擎写口：`wr_req` 拍把 `wr_data` 写入 `wr_addr`。
- CPU 与引擎写主经 `mem_write_arbiter` 收敛到唯一 RAM 写口（见 2.9 / 2.10 / 2.11）。仲裁器为时序版：每主 4 深同步请求队列 + round-robin 轮转防饥饿，双待写交替授权；CPU 写 reply 跟随授权拍回送。`cpu_full / eng_full` 背压标志已引出，尚未接回写主侧 stall 输入。
- 真实 Gowin / ASIC RAM 有一拍读延迟，挂接时需在引擎与 RAM 之间补一级读缓冲（参照原 S011 模型 `read_data_r` 做法），不改 FSM 节拍。

## 5. 后续未决项

- **已在 iverilog 端到端覆盖**：加、减、与、乘、除、无条件跳转（024）、074 绝对值跳转、条件跳转（034 正 / 负两路）、八进制与十进制 BCD 输入打包 / 输出解包。
- **尚未单独验证**：
  - 传送变体（005/015/045/055/064）除端到端加法 / IO 路径外的组合；
- IO 八进制链路已由 2a `07_add1` 端到端覆盖：纸带输入解包、符号位 / 数字 / 结束符握手、八进制输出打包，`output.bin` MD5 与 ref 一致。
- 引擎命令控制面：桥模型层 5-bit 符号流下发参数 + wait done 握手、核心固件层轮询 DONE 后写 ACK 均已在 iverilog 闭环验证（见 2.6 / 2.7）。**真实链路控制面入口与内存映射约定**仍待与最终集成形态对齐；当前固件子程序由调试口装入程序区，尚未经引擎第二段搬运装入。
- 写仲裁已在 2.10 / 2.11 升级为 4 深背压队列 + 轮转防饥饿的时序仲裁器，并发同拍不丢写、双方不被饿死。剩余边界：`full` 背压标志尚未接回 `copy_engine` / PU 写主侧 stall，满队时新请求不入队但写主侧不感知；满队丢弃 / 队头保护的定向激励未覆盖；引擎大块突发与 CPU 零散写在长时间并发下的吞吐权衡、背靠背排队深度余量尚未压测。
- 源 / 目的重叠区复制方向策略（上移 / 下移）未定；RTL 当前按低地址 → 高地址逐字搬运。
- 行为数组模型与 S011 的同步读 / 写一拍语义已对齐 2a，但未覆盖 S011 片选、位掩码等边界；上板前需回接真实 RAM 模型或 Gowin BRAM 并复核时序。
- Flash / ROM 行为模型、块目录项（镜像 ID / 入口 / 字数 / 类型 / 校验 / 标志）与校验和为后续阶段。

## 6. 回归证据清单

| 回归项 | 日志 | 结果 |
|---|---|---|
| 2a 核心直接执行 07_add1 | `regress/core-eb.log` | MD5 `75af62902c598dd73cb654aa518d1a2b`，与 ref 一致 |
| 引擎旁路 ↔ 共享 RAM 集成（含写仲裁实接、全程无 conflict） | `regress/engine-mem.log` | 17 PASS / 0 FAIL |
| 引擎搬运后核心目的区执行 | `regress/engine-core.log` | mem[3001]=7、mem[3002]=7，2 PASS / 0 FAIL，E2E PASS |
| 指令覆盖（与/乘/除/跳转） | `regress/inst-cov.log` | 10 PASS / 0 FAIL（AND、BR、MUL、DIV、CBR±） |
| 减法符号组合 + 零结果 | `regress/sub-cov.log` | 14 PASS / 0 FAIL（S1..S7，含正负零符号） |
| 074 绝对值跳转 | `regress/abs-cov.log` | 4 PASS / 0 FAIL（跳 c2、b 取绝对值） |
| IO 八进制 / 十进制 BCD / 停机 | `regress/io-cases.log` | io `67146a4f…`、io2 `843b2c87…`、io3 `1437c3c3…`，MD5 全匹配 |
| 命令块装配 + 桥模型握手（含 DONE/ERR 镜像清零） | `regress/engine-ctrl.log` | 12 PASS / 0 FAIL，saw_busy=1，落位 3 4 5，E2E PASS |
| 核心固件轮询 DONE → 写 ACK 握手（含 DONE 镜像清零） | `regress/fw-poll.log` | 7 PASS / 0 FAIL，引擎回 IDLE、ACK 自清，E2E PASS |
| 并发公平仲裁集成（引擎搬运 ↔ CPU 写并发，挂起 / 轮转 / 数据隔离 / 互斥） | `regress/cpu-eng-concur.log` | 20 PASS / 0 FAIL，CONCURRENCY PASS |
| RTL 引擎 FSM 自检 | `regress/rtl-engine-selftest.log` | 39 判据 PASS |
| RTL 写仲裁自检（4 深背压队列 + 轮转防饥饿 + FIFO 顺序 / 不饿死） | `regress/rtl-arbiter-selftest.log` | 51 判据 PASS |
| RTL 通路闭环自检 | `regress/rtl-path-loop.log` | 32 判据 PASS |
| 既有 Verilator 基线 | `verify-verilator/test/output.bin` | MD5 `de88360aa7c21c3e07e771bec9f8e150`，未回退 |
