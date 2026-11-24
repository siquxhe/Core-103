# 拷贝引擎 RTL 模块 + 写口仲裁 · 设计说明

> 日期：2026-11-24 ｜ 阶段：RTL 化第一步（引擎 FSM + 写仲裁独立闭环验证）
> 基准：与行为级 C 原型 `engine/copy_engine.c` 一一对应；未改动既有 `hardware/`、`verify-verilator/` RTL 源码。

## 1. 交付文件（均在 `c103-microprocessor/work/`）

| 文件 | 作用 |
|---|---|
| `rtl/copy_engine.v` | 拷贝引擎 7 态 FSM、命令/状态寄存器、边界检查 |
| `rtl/mem_write_arbiter.v` | 共享 RAM 写口 CPU/引擎二选一仲裁（纯组合） |
| `rtl/mem_ram_model.v` | 行为单口 RAM 模型（31 位字/12 位地址，独立 iverilog 闭环用） |
| `rtl/engine_mem_path.v` | 通路封装：引擎 + 仲裁器 + RAM + 读口复用 mux |
| `rtl/run_rtl_sim.ps1` | 回归脚本：编译、运行、落盘日志、汇总 PASS/FAIL |
| `tb_rtl/tb_copy_engine.v` | 引擎自检 testbench（含同步 RAM 模型） |
| `tb_rtl/tb_arbiter.v` | 仲裁器自检 testbench |
| `tb_rtl/tb_path_loop.v` | 内存通路自检 testbench |
| `regress/rtl-engine-selftest.log` | 引擎仿真通过日志 |
| `regress/rtl-arbiter-selftest.log` | 仲裁器仿真通过日志 |
| `regress/rtl-path-loop.log` | 内存通路仿真通过日志 |

## 2. copy_engine.v 接口与时序

时钟/复位惯例与既有 RTL 一致：`clk` 上升沿，`resetn` 低有效复位。字宽 31 位 `[30:0]`，地址 12 位 `[11:0]`，参数 `MEM_SIZE`（默认 4096）。

| 方向 | 信号 | 说明 |
|---|---|---|
| 输入 | `cmd_src[11:0]` / `cmd_dst[11:0]` / `cmd_len[11:0]` | 命令寄存器，go 之前电平保持 |
| 输入 | `cmd_go` | 启动脉冲，IDLE 态采样并锁存命令 |
| 输出 | `rd_addr[11:0]` / `rd_req` | RAM 读口地址与请求 |
| 输入 | `rd_data[30:0]` | RAM 读出字 |
| 输出 | `wr_addr[11:0]` / `wr_data[30:0]` / `wr_req` | RAM 写口（先经仲裁器） |
| 输入 | `ack_done` / `ack_err` | 完成/错误握手脉冲 |
| 输出 | `busy` / `done` / `err` / `err_code[1:0]` / `state[2:0]` / `remain[11:0]` | 状态 |

### FSM 状态对应（对齐 C 原型枚举）

| 状态 | 编码 | 行为（与 `ce_step` 逐态一致） |
|---|---|---|
| IDLE | 0 | 采样 `cmd_go`，锁存 src/dst/len，置 busy，转 ARM |
| ARM | 1 | 边界检查；非法置错误码并转 ERR，合法置指针/remain 转 FETCH |
| FETCH | 2 | 锁存 `rd_data` 到 `latch_word`，转 WRITE |
| WRITE | 3 | 驱动写口；源/目的指针 +1，remain −1，转 CHECK |
| CHECK | 4 | remain=0 → 清 busy、置 done、转 DONE；否则回 FETCH |
| DONE | 5 | 等 `ack_done` 握手，回 IDLE |
| ERR | 6 | 等 `ack_err` 握手，清 err/错误码，回 IDLE |

### 边界检查（组合，ARM 态采样）

优先级与 C 原型一致：

1. `len == 0` → `err_code = ZERO_LEN(3)`
2. 源区间越界（`src ≥ MEM_SIZE` 或 `src+len-1 ≥ MEM_SIZE`）→ `SRC_OOB(1)`
3. 目的区间越界 → `DST_OOB(2)`

边界和用 13 位加法判断，避免 12 位内回绕误判。

## 3. mem_write_arbiter.v 仲裁规则

两个写主：CPU（内核数据通路）、引擎。纯组合，无触发器。

- 引擎优先：`grant_eng = eng_wr_req`；CPU 仅在引擎无请求时获授权 `grant_cpu = cpu_wr_req & ~eng_wr_req`；
- 双方同时请求：`conflict = 1`，授权仍归引擎，CPU 本次请求被阻塞；
- 输出到 RAM 的地址/数据按 `eng_wr_req` 二选一透传。

**本阶段边界**：不缓冲、不挂起 CPU 请求，不做公平仲裁。系统约定为"装载期核心停住、引擎独占写口"，因此不会出现需要 CPU 并发写入的场景。后续若允许并发，再在此模块加请求挂起与公平仲裁寄存器。

## 3.5 通路封装 engine_mem_path（独立 iverilog 闭环）

`engine_mem_path.v` 把引擎、仲裁器、行为 RAM 接成一条完整内存通路，供 work/ 下独立 iverilog 工程验证，**不改动既有 verify/hardware 仓库工程**：

```
CPU 写主 ──┐
            ├─ mem_write_arbiter ──→ RAM 写口
引擎 写主 ──┘

CPU 读主 ──┐
            ├─ 读地址 mux ──→ RAM 读口 ──→ 引擎 / CPU 读数据
引擎 读主 ──┘
```

- **CPU 主侧端口**（`cpu_wr_*` / `cpu_rd_*`）第一步由 testbench 模拟；第二步接 `core_top` 既有内存口时直连，封装内部不改。
- **读口复用**：读地址 mux 引擎优先；CPU 读数据视图与引擎读数据同源。
- **调试口**（`dbg_wr_*` / `dbg_rd_*`）：testbench 直接预填镜像、直读校验，不参与功能通路。
- **RAM 模型** `mem_ram_model.v`：31 位字、12 位地址、同步写、组合读；仅用于独立闭环，不替代既有 S011 / Gowin_SP 存储实例。

## 4. 时序假设与挂接要点

1. **读延迟**：testbench 内 RAM 模型为组合读（FETCH 态当拍数据有效），FSM 节拍与 C 原型严格对齐。真实 Gowin/ASIC RAM 有一拍读延迟，挂接时在引擎与 RAM 之间补一级读缓冲（参照 `memory_fpga.v` 的 `read_data_r`），不改本 FSM。
2. **写口挂接**：引擎 `wr_*` 先接 `mem_write_arbiter` 的引擎侧；CPU 既有写口（`sel_value_from_sel` + `{write_sign_from_ac, write_data_from_au}`）接仲裁器 CPU 侧；仲裁器输出再接既有 RAM 写口。
3. **未接入内核**：本阶段引擎/仲裁为独立模块，未例化进 `core_top`；既有 Verilator 工程的源文件清单未引用 `work/rtl/`，内核通路保持原 103 行为。
4. **重叠区**：源/目的重叠时的上移/下移方向策略尚未确定，RTL 暂按向前（低地址→高地址）逐字搬运；确定策略后再在 FETCH/WRITE 顺序上调整。

## 5. 验证证据

### 5.1 功能仿真（Icarus iverilog/vvp 14.0）

| 测试台 | 用例 | 判据数 | 结果 |
|---|---|---|---|
| `tb_copy_engine` | E1 单块装载落位 + 握手回 IDLE；E2 源越界；E3 目的越界；E4 零长度；E5 握手后复装 | 39 | PASS，0 失败 |
| `tb_arbiter` | A1 仅引擎；A2 仅 CPU；A3 双请求冲突引擎优先；A4 均无请求 | 21 | PASS，0 失败 |
| `tb_path_loop` | P1 镜像经通路搬运落位 + 哨兵未写；P2 空闲 CPU 写直通 / 搬运期引擎授权；P3 握手后复装；P4 源越界经通路透传 | 32 | PASS，0 失败 |

复现：`pwsh -File work/rtl/run_rtl_sim.ps1`。三组合计 92 判据全 PASS。

### 5.2 综合检查（Yosys 0.71）

- `copy_engine`：综合出 111 个带使能/异步复位 DFF（`$_DFFE_PN0P_`），无锁存残留、无组合环、无未连接端口告警；
- `mem_write_arbiter`：纯组合 46 单元、0 DFF，与设计预期一致；
- `engine_mem_path` 通路顶层：综合无 ERROR、无组合环、无未连接端口告警；4096×31 RAM 推断为存储单元，引擎寄存器全部转为 DFF，无意外锁存。

### 5.3 既有基线回归（未回退）

| 基线 | 结果 |
|---|---|
| C 模拟器 test-program | PASS 17 / DIFF 0 / N/A 3 / 无输出 0 |
| 汇编一致性 | PASS 20 / DIFF 0 |
| Verilator `test/output.bin` MD5 | `de88360aa7c21c3e07e771bec9f8e150`，与 `output.bin.ref` 一致 |

四个既有仓库工作区干净，本阶段新增文件全部隔离在 `work/` 内。

## 6. 遗留与下一步

1. **接核心内存口（第二步）**：通路封装 `engine_mem_path` 的 `cpu_wr_*`/`cpu_rd_*` 主侧直连 `core_top` 既有内存口。前置排查已完成：core 拷贝副本（`work/ip_core/`）在 iverilog 下 elaboration 通过；唯一语法坑为 `memory.v` 4 处 `128'h_` 字面量，副本已修复。待补 shell 顶层/移位寄存器模型与核心驱动 testbench。
2. **执行装入代码**：2a 已在独立 iverilog 工程跑通核心直接执行冻结程序（`work/ip_core/`，output 与参考 MD5 一致）；2b 待把引擎读写口接入既有 `memory.v` 单口 RAM，镜像经引擎搬到目的区后，预置 `strt` 指向目的区入口启动核心并校验结果。
3. **指令级触发**：定义核心如何经现有 5-bit 符号流下发 `src/dst/len/go`，并轮询 `busy/done`（当前由 testbench 直接驱动命令接口）。
4. **重叠区策略**：确定重叠复制方向后固化搬运顺序。
5. **形式验证**：对仲裁互斥、握手回 IDLE、计数器边界等可穷举性质补 sby 断言（本阶段以功能仿真 + 综合检查为终点）。
