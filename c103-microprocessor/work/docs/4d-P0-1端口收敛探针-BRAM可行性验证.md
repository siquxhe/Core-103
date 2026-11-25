# 4d · P0-1 端口收敛探针：主存进块 RAM 可行性验证

> 关联：`4c-Gowin综合复核-BRAM推断定位.md`（阻碍定位）、`4a-M3-103容量调研与BRAM改造方案.md` §7。
> 口径：资源数以 `*_syn_rsc.xml` 的 `T_` 总计为准；Fmax 为综合估算，无 SDC 约束。
> 器件：`GW1NSR-LV4CQN48PC6/I5`（FF 3573 / BSRAM 10 / LUT 4608）。

## 1. 结论先行

把主数组端口收敛到 **单写 + 双同步读（CPU 主读 + eng 旁路读）** 的双口 BRAM 模板后，内核综合**成功越过 RAM 推断阶段，主存不再退回 DFF 阵列**：

| 指标 | 改造前（4c 现状） | 收敛探针（本文件） |
| --- | --- | --- |
| 综合退出 | 失败 IF0008 | **成功 exit 0** |
| 主存形态 | 63488 DFF 阵列 | **BSRAM 块 RAM** |
| BSRAM | 0 | **8**（利用率 80%，分母 10） |
| FF | 63488（超限） | **598**（17%，分母 3573） |
| LUT / ALU | — | 785 / 64（Logic 19%） |
| Fmax / Level | 未取得 | 64.45 MHz / 10 级 |

> BSRAM 主体为主存 `mem`；写仲裁器两路请求队列（`cpu_q`/`eng_q`，FIFO_DEPTH=4、条目 43 位）为小队列，归 FF/LUTRAM，不占块 RAM。

## 2. 探针构造

为不污染 iverilog 回归基线，综合侧单独构造收敛变体目录 `work/regress/synth-converged/`：

- 复制内核 `core/*.v`（除正本 `memory.v`）+ `rtl/mem_write_arbiter.v`；
- 变体 `memory.v` 对外端口与正本一致（`core_top` 连线不改），内部把主数组访问收敛为：
  - **唯一功能写口**：仲裁器输出 `ram_wr_req/addr/data`；
  - **两个同步读口**：CPU 主读 `read_data_r`、eng 旁路 `eng_rd_data_r`；
  - dbg 调试写旁路不写数组；ctrl / dbg 旁路读不直读数组（输出归零，占位待命令块收敛方案落地）。

综合命令：
```
python <gowin-toolchain>/scripts/synth.py --src <synth-converged 目录> `
    --top core_top --pn GW1NSR-LV4CQN48PC6/I5 --outdir <synth-converged/build>
```

产物：`work/regress/synth-converged/build/`（`core_top_syn_rsc.xml`、`core_top_result.json`、`core_top_run.log`、报告 html）。

## 3. 与 4c 阻碍定位的对应验证

4c 探针矩阵定位的三项阻碍，在本变体中逐项剥离后均解除：

| 阻碍（4c） | 探针证据 | 本变体处理 | 结果 |
| --- | --- | --- | --- |
| 双时序写口（dbg 调试写） | v2 / v5 退回 63488 DFF | dbg 写不挂数组，仅留仲裁后单写 | 双写阻碍解除 |
| 组合直读口（ctrl / dbg） | v4 退回 63488 DFF | ctrl/dbg 读不直读数组 | 组合读阻碍解除 |
| 读口超双口（4 读） | v6 三读口退回 32784 DFF | 读口只留 CPU + eng 两个同步读 | 超容量阻碍解除 |

变体综合日志完整走过 `Running inference`（Phase 0–3）与 `Running technical mapping`（Phase 0–4），无 IF0008 / RP0001 超限报错；`Extracting RAM for identifier 'mem'` 后成功映射为 BSRAM。

## 4. 尚未闭环的部分（命令块 / 调试口落点）

本变体是**综合可行性探针**，ctrl/dbg 通路在变体中被占位归零，尚未在交付 RTL 中给出真实去处。落正本前需定命令块收敛路线：

### 路线甲：命令块剥离为 engine_ctrl 本地寄存器组

- engine_ctrl 内部维护 8 字命令块（2400–2407）寄存器；参数（SRC/DST/LEN/GO）由 CPU/纸带写通路译码旁路更新本地；状态镜像（BUSY/DONE/ERR/ACK）本地保存并回写主存副本，供 CPU 固件经主读口轮询。
- **优点**：本地寄存器组为组合读/小寄存器，不受 BRAM 同步读一拍延迟约束，`engine_ctrl` 紧凑 FSM 不必改读节拍，规避 4b 实测的 ctrl 同步读滞后一轮回归。
- **代价**：跨 memory（写地址译码旁路）+ engine_ctrl（本地存储/双写镜像）+ tb（命令块预填改道）；需保证本地与主存状态副本一致。

### 路线乙：命令块留主存，第二读口分时复用

- 命令块保留在主数组；eng 搬运读与 ctrl 装配读、dbg 校验读经使能仲裁 + 地址 mux 共享第二读口，BRAM 输出统一同步锁存到各主。
- **优点**：命令块位置与 CPU 读镜像路径零改动；贴合 4a §7.2 原方案。
- **代价**：第二读口复用仲裁时序；`engine_ctrl` 需按同步读一拍延迟补等待拍（4b 已踩 ctrl 同步读滞后坑）；复用 mux 是否被综合器接受为双口 BRAM 需再验证。

### 推荐

优先**路线甲**：命令块本质是外设控制寄存器而非通用数据 RAM，剥离后主存端口天然收敛；且本地寄存器组合读不引入 BRAM 读延迟，FSM 节拍零改动，回归风险低于乙。路线乙作为退路：若甲的写译码/双写镜像面过大，再回到分时复用。

## 5. 仿真 / 综合模型分层口径

- Gowin 综合器 CLI **无 `-D` 宏定义注入参数**（仅 `-inc` include 路径）；`ifdef` 双模型不能靠综合器切宏。
- 落地采用 4a §7.4 的存储内核层分层：iverilog 仿真跑全端口行为数组模型（保既有回归基线），综合喂收敛端口的 BRAM 模型；两个模型经文件/参数切换，不靠编译宏。
- dbg 预填/直读校验为仿真专用通路，上板量产形态整口移除；其硬件预填/加载通路留待 P0-2 Flash/ROM 链路一并定。

## 6. 遗留

- 命令块路线（甲/乙）待拍板后再落正本 `memory.v` / `engine_ctrl.v` 与对应 tb；落正本后须复跑九套内核套件 + core-eb + IO 三例，基线 MD5 零回退。
- 变体中 eng 读口在 `core_top` 未接引擎（旁路悬空，CV0016/18）；真实双口连接下的 BSRAM 块数与读路径 Fmax，待 wrapper 接 `copy_engine` 激励后复核。
- 本探针无 SDC 时钟约束，Fmax 64.45 MHz / Level 10 为综合估算，真实时序以 P&R 后报告为准。
