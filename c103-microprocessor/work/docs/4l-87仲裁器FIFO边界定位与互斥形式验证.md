# 4l · #87 仲裁器 FIFO 满队边界定位与互斥形式验证

> 范围：定位 #84 阶段 B 高压灌满载队时"队尾一笔未落 RAM"的根因，判定是 RTL 缺陷还是 tb 观测口径问题；并对仲裁器核心不变量补形式验证。
> 本文结论基于本轮仿真守恒计数与 sby 形式验证第一手结果；未改 RTL 设计。
> 关联文档：4j（#84 仲裁加压用例）、hdl-design-verify 验证闭环。

## 一、结论先行

- **根因：非 RTL 缺陷。** 仲裁器 FIFO 无丢笔、无槽位覆盖、无双授权。#84 旧判据看到的"cpu[11] 未落 RAM"是 **tb 满队边缘采样误标**：旧 present 集合在 negedge 对 `!cpu_full` 采样，与 RTL posedge 入队存在边缘拍错位，把满队背压拒入的笔误标为"应落位"。实际入队的笔全部落位，排空后两队列均 empty。
- **仿真守恒成立**：两突发规模下，每主 `入队 == 出队授权 == RAM 落位`，计数守恒。
- **形式验证**：授权互斥不变量 sby prove **PASS**；cover 确认满队标志可达、双授权不可达（符合预期）。

## 二、定位过程与证据

### 2.1 静态复核 RTL 指针语义

`mem_write_arbiter` 为标准 2^N 同步 FIFO：DEPTH=4，PW=2，指针 3 位（多 1 位判满空）。
- empty：`wp == rp`；full：高位不同且低 N 位相等。
- 入队：`wr_req && !full`，写 `q[wp[PW-1:0]]`，wp++；出队：`grant && !empty`，rp++。
- 判据用沿前旧指针电平，wp/rp 沿后更新；满队拒入、空队拒出，同拍入出不冲突槽位。
- 授权互斥：`grant_cpu = cpu_pending && (!eng_pending || last_eng)`，`grant_eng` 对称；RAM 单写口。

静态未见指针回绕错乱或槽位覆盖。

### 2.2 守恒计数仿真（定位关键）

在 tb 侧按与 RTL 一致的口径（沿前电平）统计：入队事件 `wr_req && !full`、出队授权 `grant`、RAM 落位 `ram_wr_req && grant`。

| 场景 | CPU enq/deq/wr | 引擎 enq/deq/wr | 排空终点 |
|---|---|---|---|
| 阶段 B，BURST=12 | 8 / 8 / 8 | 9 / 9 / 9 | 两队列 empty |
| 阶段 B，BURST=32 | 18 / 18 / 18 | 19 / 19 / 19 | 两队列 empty |

- 入队数 = 出队授权数 = RAM 落位数，双主均守恒；若存在丢笔或槽位覆盖，队列项数/落位数将对不上。
- RAM 落位清单中未落位的槽位，对应满队拍被背压拒入的请求（CPU/引擎各若干笔），本就不该落 RAM。

### 2.3 形式验证（sby）

新增 `formal/arb_formal_wrapper.sv`（例化仲裁器，断言只用外部可见端口）+ `formal/arb_formal.sby`。

- **prove（abc pdr）**：`assert property (!(grant_cpu && grant_eng))` —— **PASS**，授权互斥在所有可达状态成立。
- **cover（smtbmc z3）**：
  - `cpu_full` / `eng_full` **reached**：满队背压路径真实可达；
  - `grant_cpu && grant_eng` **unreached**：双授权不可达，反向校验互斥成立。
  - 注：sby cover 任务因该反向 cover 未到达返回 rc=2，属预期结果，非失败。

### 2.4 工具链踩坑（供后续形式验证参考）

- 断言必须用 SVA 写法 `assert property (...)` / `cover property (...)`；裸 `assert (...)` 在 yosys 前端报 `expecting TOK_PROPERTY`。
- 断言**不能跨层次读内部寄存器**（如 `dut.cpu_wp`）：yosys 将其判为"used but has no driver"的 wire，污染模型并导致 witness 信号映射失配。队列项数/不溢出这类需内部指针的性质，不宜在 wrapper 跨层次断言。
- SystemVerilog 断言文件用 `.sv`，sby script 用 `read_verilog -sv -formal` 读入。

## 三、本轮改动

| 产物 | 路径 | 角色 |
|---|---|---|
| `tb_arb_concur.v` | `ip_core/tb/` | 阶段 B 新增判据 B4 守恒：`enq==deq==wr` 双主；DIAG 打印守恒计数 |
| `arb_formal_wrapper.sv` | `formal/` | 形式验证包装层，互斥断言 + 满队/双授权 cover |
| `arb_formal.sby` | `formal/` | sby 任务：prove（abc pdr）+ cover（smtbmc z3） |

回归：`ARBCONC PASS=64 FAIL=0`；全量 16 条既有回归脚本全 PASS，无回退。

## 四、未覆盖与遗留

- **队列不溢出（项数 ≤ DEPTH）的形式建模未做**：该性质需内部 wp/rp 指针，wrapper 跨层次引用不被 yosys 支持；当前由仿真守恒计数 + full 拒入逻辑覆盖。若后续需形式化，应在 RTL 模块内部 `ifdef FORMAL` 段对本地指针断言，而非 wrapper 跨层次读取。
- **不丢守恒的跨周期形式证明未做**：属跨计数器性质，需在断言侧建模影子计数器；仿真守恒用例已覆盖当前激励路径。
- 仲裁器其余数据通路数值结果仍以功能仿真为准；形式 PASS 不替代仿真观察，亦不代表时序收敛。

## 五、复现命令

```
# 仿真守恒 + 编码自洽
pwsh -File ip_core/run_arb_concur.ps1

# 形式验证（在 formal/ 目录）
sby -f arb_formal.sby prove
sby -f arb_formal.sby cover
```
