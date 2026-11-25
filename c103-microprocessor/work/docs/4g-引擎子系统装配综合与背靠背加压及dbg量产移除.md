# 4g · 引擎子系统装配 wrapper 综合统计 · 背靠背加压一致性 · dbg 量产移除

> 范围：把 `copy_engine + engine_ctrl + 写仲裁器 + memory` 接成完整可综合装配顶层，跑 Gowin 资源统计；
> 编写正本/仓内副本双份一致性的背靠背加压用例；明确 dbg 预填通路在量产/综合形态的剥离边界，
> 仿真整镜像装载通路切到已落地的 `image_loader`。
> 器件：`GW1NSR-LV4CQN48PC6/I5`；综合器：GowinSynthesis 1.9.11.03（Education）。

## 一、装配 wrapper 与综合统计

### 1.1 装配对象与连线

引擎子系统顶层 `engine_subsys_wrapper`（`regress/synth-engine/engine_subsys_wrapper.v`）直接例化三个交付模块，不再经过内核 `core_top` 的 arith/IO/译码层：

| 子模块 | 来源 | 职责 |
|---|---|---|
| `memory`（内含 `mem_write_arbiter`） | `ip_core/core/memory.v` 的综合变体 | 行为数组存储 + 双主写仲裁 |
| `engine_ctrl` | `rtl/engine_ctrl.v` | 命令块 FSM + 本地 `cmd_q` 寄存器组 + 状态镜像回写 |
| `copy_engine` | `rtl/copy_engine.v` | 搬运 FSM + 自适应重叠区方向 |

内部连线（对齐既有 `tb_engine_ctrl.v` 装配关系）：

- **eng 旁路**：`copy_engine` 读口 ↔ `memory.eng_rd_*`；写口 ↔ `memory.eng_wr_*`。
- **ctrl 旁路**：`engine_ctrl.ctrl_rd/wr_*` ↔ `memory.ctrl_*`。
- **命令块本地寄存器**：`memory.cmd_wr_*`（功能写命中 2400..2407）→ `engine_ctrl.local_wr_*`。
- **引擎背压**：`memory.eng_stall` → `copy_engine.wr_stall`（补齐既有 tb 悬空缺口）。
- **memory CPU 主读写口**：子系统内不接内核，输入 tie 0。
- **dbg 调试口**：量产/综合形态 tie 0，不参与装配。

对外端口：时钟/复位；命令块参数写入口（量产形态由装载器/固件驱动）；状态观测输出 `busy/done/err/err_code/eng_state/remain`；仲裁观测 `grant_cpu/grant_eng/arb_conflict/cpu_stall/eng_stall`。

### 1.2 综合资源（正本 / 副本一致）

| 资源 | 引擎子系统 wrapper | 利用率 | 器件总量 |
|---|---:|---:|---:|
| FF（寄存器） | **816** | 23% | 3573 |
| LUT（LUT4） | **825**（logic_lut 890） | 20% | 4608 |
| BSRAM | **4** | 40% | 10 |
| ALU | 65 | — | — |
| DSP / SSRAM | 无 | — | — |
| Fmax（综合估算） | **55.404 MHz** | — | — |
| 逻辑级数 | 10 | — | — |

- 综合退出码 0，日志无 ERROR / WARNING / 黑盒；主存数组与仲裁队列均推断为存储单元。
- 正本目录与仓内副本目录各跑一次 Gowin 综合，上表数值逐项一致（见 §2.3）。

> **口径提醒（不可与既有 core_top 基线混比）**：既有 `synth-converged` 基线是**整核 `core_top`**（含 arith/IO/译码），且当时 `engine_ctrl/copy_engine` 未纳入综合、命令块旁路归零；
> 本轮 wrapper 是**引擎子系统口径**，首次纳入引擎 FSM、装配 FSM 与仲裁队列。两者资源构成不同，FF/LUT/BSRAM 数字不能直接相减比较。
> 既有整核基线（仅供参照）：ff 598 / lut 785 / bsram 8 / fmax 64.452 MHz / level 10。

### 1.3 综合变体口径

Gowin 综合 CLI 无 `-D` 宏注入，不能用 `ifdef` 双模型，故综合形态由文件/目录切换变体：

- 变体目录：`regress/synth-engine/`（非交付 RTL，仅综合验证用）。
- 变体 `memory.v`：唯一功能写口经仲裁器落数组；CPU 主读、eng 旁路为同步读；**dbg 调试写不写数组**；**ctrl/dbg 旁路读不直读数组（输出归零，消除组合读阻碍）**；命令块写旁路保留，功能写命中 2400..2407 时透传 `engine_ctrl` 本地寄存器组。

## 二、背靠背加压用例与双份一致性

### 2.1 用例覆盖矩阵

测试台 `ip_core/tb/tb_engine_backpressure.v`，装配 `memory + engine_ctrl + copy_engine`（不挂内核），连续跑 9 段背靠背搬运：

| 段 | 场景 | 源 → 目的 | 长度 | 期望 |
|---|---|---|---:|---|
| 1 | 正向不重叠 | 0300 → 0500 | 12 | DONE，逐字落位 |
| 2 | 反向重叠（dst>src，重叠） | 0700 → 0710 | 16 | DONE，反向复制落位 |
| 3 | 正向重叠（dst<src） | 0760 → 0740 | 16 | DONE，正向复制落位 |
| 4 | 长度 1 边界 | 1300 → 1320 | 1 | DONE |
| 5 | 长段 | 1400 → 1550 | 48 | DONE，逐字落位 |
| 6 | 背靠背重复（段 1 参数 ×3） | 0300 → 0500 | 12 | 每段握手后无残留、可接续 |
| 7 | 源越界 | 3540 → 2720 | 200 | ERR，`err_code=1`（SRC_OOB） |
| 8 | 目的越界 | 0300 → 3540 | 200 | ERR，`err_code=2`（DST_OOB） |
| 9 | 零长 | 0300 → 0400 | 0 | ERR，`err_code=3`（ZERO_LEN） |

判据：

- 成功段：引擎 `done` 握手；目的区逐字等于源区初始值（`verify_dst`）。
- 错误段：引擎 `err` 握手；`err_code` 与期望码一致（以引擎 wire 为准）。
- 每段 ACK 握手后状态机回 IDLE；命令块主存镜像落位由既有 `tb_engine_ctrl` 回归覆盖，本用例不重复判主存镜像。

### 2.2 仿真结果

- 正本工作区：`BACKTOBACK PASS=154 FAIL=0`，`BACKTOBACK E2E PASS`，仿真结束时刻 `4358000 ps`。
- 仓内副本：`BACKTOBACK PASS=154 FAIL=0`，`BACKTOBACK E2E PASS`，结束时刻同为 `4358000 ps`（确定性一致）。
- 回归脚本：`ip_core/run_engine_backpressure.ps1`；留档日志 `regress/engine-backpressure.log`。

### 2.3 双份一致性核对

| 核对项 | 正本 `work/` | 仓内副本 `Core-103/.../work/` | 结论 |
|---|---|---|---|
| `rtl/engine_ctrl.v` | MD5 A4D7BA1E… | 同 | SAME |
| `rtl/copy_engine.v` | DBB5607B… | 同 | SAME |
| `rtl/mem_write_arbiter.v` | 81D5A815… | 同 | SAME |
| `rtl/image_loader.v` | 1E46251B… | 同 | SAME |
| `ip_core/core/memory.v` | 8E734F26… | 同 | SAME |
| `tb/tb_engine_backpressure.v` | — | 同 | SAME |
| 加压仿真结果 | PASS=154 / FAIL=0 | PASS=154 / FAIL=0 | 一致 |
| Gowin 综合结果 | ff816/lut825/bsram4/fmax55.404 | 同 | 一致 |

### 2.4 本轮 RTL 修复（综合暴露）

综合首跑报 `engine_ctrl` 的 `cmd_q` 被两个 `always` 块双驱动（iverilog 仿真容忍、综合报 multiple drivers）：
- 现象：`Net 'cmd_q[0][30]' is constantly driven from multiple places`，模块退化为黑盒。
- 修复：把 `cmd_q[0..7]` 的复位清零从主时序块并入命令块写口块，单一时序块驱动；行为不变。
- 既有 `tb_engine_ctrl` / `tb_engine_mem` 回归复跑仍 PASS，无回退。

## 三、dbg 预填通路量产移除

### 3.1 三层口径

| 层 | dbg 口处理 | 说明 |
|---|---|---|
| 正本行为模型 `core/memory.v` | **保留** dbg 写/直读 | 4e §6.1 既定口径：行为模型供 testbench 预填源区、直读校验，不参与综合资源评估 |
| 综合变体 `regress/synth-engine/memory.v` | **剥离** | dbg 写不进数组；dbg/ctrl 组合读归零；dbg 不参与命令块命中 |
| 量产 wrapper `engine_subsys_wrapper.v` | **tie 0** | dbg 输入接 0，输出悬空，不连内部逻辑 |

`rtl/engine_mem_path.v`、`rtl/mem_ram_model.v` 的 dbg 口属早期独立 iverilog 闭环通路，不进内核综合链路；内核主存以 `memory.v` 为准。

### 3.2 仿真装载通路替代

- 量产/综合形态不依赖 dbg 预填；整段主存镜像装载走已落地的 **`image_loader`**（RTL FSM：IDLE/CHECK/WIPE/LOAD/DONE/ERROR，`$readmemh` 读文本镜像）。
- 镜像打包链路：`image-pack`（段定义 + `input.103` → `image.bin/.hex`）→ simulator `-m` 装载 / RTL `image_loader` 装载。
- 镜像装载回归复跑：**PASS 21 / FAIL 0**（C 侧正向 1 + C 侧报错 10 + RTL 正向 1 + RTL 报错 9），正向基线 MD5 `00a84cb87f46cbab5a2e0f1f73a909d2`。
- 加压测试台内的源区预填 / 直读校验仍经正本行为模型 dbg 口，属测试夹具，不代表量产装载路径。

## 四、本轮改动与新增文件

**新增（正本 `c103-microprocessor/work/`）**

- `regress/synth-engine/engine_subsys_wrapper.v` — 引擎子系统装配顶层（综合统计用）。
- `regress/synth-engine/memory.v` — 引擎子系统综合变体（剥离 dbg 写 / 组合读）。
- `ip_core/tb/tb_engine_backpressure.v` — 背靠背加压 testbench。
- `ip_core/run_engine_backpressure.ps1` — 加压回归脚本。

**修改**

- `rtl/engine_ctrl.v` — `cmd_q` 复位并入写口块，消除综合多驱动（行为不变）。

**同步仓内副本**：上述 `engine_ctrl.v`、加压 tb、回归脚本、`synth-engine/` 变体源码已复制到 `Core-103/c103-microprocessor/work/`，MD5 全一致；`build/` 网表/报告/资源快照按 `.gitignore` 惯例不冻结。

## 五、回归证据

| 回归 | 结果 |
|---|---|
| `run_engine_ctrl.ps1`（既有装配闭环） | ENG-CTRL PASS |
| `run_engine_mem.ps1`（引擎 ↔ 共享 RAM） | ENGINE-MEM INTEGRATION PASS |
| `run_engine_backpressure.ps1`（本轮加压） | BACKTOBACK PASS=154 / FAIL=0 |
| `regress-image-loader.ps1`（镜像装载） | PASS 21 / FAIL 0 |
| Gowin 综合（正本 / 副本） | exit 0，资源逐项一致 |

## 六、遗留与未决

- 命令块参数在量产形态由谁驱动（`image_loader` 装载后固件写命令块，还是装载器直写）尚未在系统层定型；wrapper 已预留命令写入口。
- 加压用例当前覆盖背靠背重复、正反重叠、长度 1、长段与三类错误；CPU 写与引擎写同拍并发争写的定向加压可在后续补充。
- 综合 Fmax 为综合估算，真实时序以 P&R 为准；当前环境无开发板，未跑布局布线。
- 外部提交 / 推送须显式确认后再执行（身份 `siquxhe <wuqiyou2002@126.com>`，远端 `siquxhe/Core-103`）。
