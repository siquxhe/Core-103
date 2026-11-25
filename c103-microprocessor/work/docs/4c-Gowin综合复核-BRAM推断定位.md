# 4c · Gowin 综合复核：主存是否进块 RAM（BSRAM）定位

> 关联：`4a-M3-103容量调研与BRAM改造方案.md` §7、`4b-P0-1引擎读通路同步BRAM改造记录.md`。
> 口径：资源数以 Gowin 综合报告 `*_syn_rsc.xml` 的 `T_` 总计为准；Fmax 为综合估算，真实时序以 P&R 后报告为准。仿真 PASS ≠ 综合推断通过 ≠ 时序收敛。
> 器件：`GW1NSR-LV4CQN48PC6/I5`（FF 上限 3573，BSRAM 总数 10）；工具 Gowin V1.9.11.03 Education `GowinSynthesis.exe`。

## 1. 复核结论（先行）

**改造后现状主存 `mem` 仍未进块 RAM，综合在 RAM 推断阶段退回 63488 个 DFF（2048×31），报 IF0008 超器件 FF 上限。** 本轮 P0-1 的 eng 旁路同步读化方向本身与 BRAM 模板兼容，但**不是主存进块 RAM 的卡点**；真正阻碍推断的是另外三处端口结构：

1. **双时序写口**：功能写（仲裁后 `ram_wr_req`）+ dbg 调试写旁路（`dbg_wr_en`）同时写行为数组；
2. **组合直读口**：`ctrl_rd_data`、`dbg_rd_data` 为 `assign ... = mem[addr]` 异步组合读；
3. **读口总数 4**（CPU / eng / ctrl / dbg），即便全部改同步读，第三读口也超出双口 BRAM 模板容量。

探针分级隔离（§3）已分别证实上述因素：双写语义、组合读口、第三读口任一存在，综合器都无法把数组整体映射为块 RAM；双同步读（CPU + eng 两口）则可正常进 BSRAM。

## 2. 现状 RTL 综合结果

源清单：`ip_core/core/*.v`（9 个）+ `rtl/mem_write_arbiter.v`，顶层 `core_top`。产物目录 `work/regress/synth-gowin-core-top2/`。

- `Extracting RAM for identifier 'mem'`（memory.v:66）后，`Running inference` 阶段报：
  `ERROR (IF0008): The number(63488) of DFF used to infer "mem" exceeds the resource limit(3573)`。
- 旁路悬空告警：`CV0016/18` —— `eng_rd_req`、`eng_rd_addr`、`ctrl_rd_req`、`ctrl_rd_addr`、`dbg_rd_addr` 在 `core_top` 顶层引出后无激励（`core_top` 未实例化 `copy_engine` / `engine_ctrl`）。
- 与改造前（3a §3.4）同一条 IF0008、同一 63488 DFF：**eng 口同步读化没有改变主存的资源形态**。

> 注：`core_top` 未接引擎/装配模块，旁路输入被优化；但 `ctrl_rd_data` / `dbg_rd_data` 等组合读输出仍引出顶层，组合读路径未被整体裁掉，阻碍依旧。

## 3. 探针分级实验

在 `work/regress/ram-probe/` 构造参数化最小 RAM 探针（2048×31），每次只叠加一个变量，跑同器件综合，读 `*_syn_rsc.xml` / `*_syn_resource.html`。

| 探针 | 写口 | 读口 | 综合退出 | BSRAM | FF | 报错 |
| --- | --- | --- | --- | --- | --- | --- |
| v1 `probe_v1_1w1r.v` | 1W 同步 | 1R 同步 | 0 | **4** | 0 | —（基线通过） |
| v2 `probe_v2_2w1r.v` | **2W**（同 always 块） | 1R 同步 | 1 | 0 | 63488 | IF0008 |
| v5 `probe_v5_2w_split.v` | **2W**（两个独立 always 块） | 1R 同步 | 1 | 0 | 63488 | IF0008 |
| v3 `probe_v3_1w2r.v` | 1W | **2R** 同步（双口） | 0 | **8** | 0 | —（双同步读通过） |
| v4 `probe_v4_combo.v` | 1W | 1R 同步 + **1 组合直读** | 1 | 0 | 63488 | IF0008 |
| v6 `probe_v6_1w3r.v` | 1W | **3R** 全同步 | 1 | 0 | 32784 | RP0001 |

原始计数核对（rsc.xml `Module` 标签）：

- v1：`Lut="2" Bsram="4" T_Bsram="4(4)"`，无 Register 总计；
- v3：`Lut="2" Bsram="8" T_Bsram="8(8)"`，无 Register 总计。

判读：

- **v1 通过**：标准 1 写 1 读同步模板可被 Gowin 推断为块 RAM，工具链/器件/模板无问题。2048×31 占 4 块 BSRAM。
- **v2 / v5 失败**：两个时序写口无论写在同一 always 块还是拆成两个独立 always 块，都退回 63488 DFF。结论：**双写语义本身不被该器件 BSRAM 双口模板接受**（双口为一口写、一口读），不是代码写法问题。
- **v3 通过**：1 写 + 2 同步读进块 RAM（8 块，双口读位宽翻倍）。说明 **CPU 主读 + eng 旁路读这两个同步读口落在双口 BRAM 容量内，本轮 eng 同步读化与块 RAM 兼容**。
- **v4 失败**：仅加一个组合直读口 `assign combo = mem[addr]` 即退回 63488 DFF。**异步组合读是 BRAM 推断的硬阻碍**（块 RAM 只支持同步读）。
- **v6 失败**：三个全同步读口也未整体进块 RAM（32784 DFF，综合器改走复制 + 分布式/寄存器结构）。**读口数超过双口（2 读）后，行为数组无法映射单块双口 BRAM。**

## 4. 阻碍因素映射到 `memory.v` 现状

`work/ip_core/core/memory.v` 的数组 `mem[0:2047]`（31 位）：

| 端口 | 现状写法 | 对应探针 | BRAM 兼容性 |
| --- | --- | --- | --- |
| CPU 主读 | `read_data_r <= mem[addr_rd_r]`，时序读 | v3 读口 1 | 兼容（同步读） |
| eng 旁路读 | `eng_rd_data_r <= mem[eng_rd_addr]`，时序读 | v3 读口 2 | 兼容（同步读） |
| 功能写 | `if (ram_wr_req) mem[ram_wr_addr] <= ram_wr_data;` 时序写 | v1 写口 | 兼容（单写） |
| **dbg 调试写** | `if (dbg_wr_en) mem[dbg_wr_addr] <= dbg_wr_data;` 时序写（第二写口） | v2 / v5 | **阻碍：双时序写** |
| **ctrl 旁路读** | `assign ctrl_rd_data = mem[ctrl_rd_addr];` 组合直读 | v4 | **阻碍：组合读** |
| **dbg 旁路读** | `assign dbg_rd_data = mem[dbg_rd_addr];` 组合直读 | v4 | **阻碍：组合读** |
| 读口总数 | CPU + eng + ctrl + dbg = 4 | v6 | **超双口 2 读容量** |

即：本轮把 eng 口从组合读改成同步读，消除的只是"eng 这一路组合读"；ctrl/dbg 两路组合读、dbg 第二写口、四读口超容量这三项阻碍仍在。

## 5. 可行路径（对应 4a §7.2 / §7.4）

要让主存整体进块 RAM，需先把数组端口收敛到"单写 + 最多两读同步"的双口 BRAM 模板：

1. **写口收敛为单写**：dbg 调试写旁路在综合形态下不挂功能存储口——预填/复位数据由加载期专用通路或仿真期模型承担；运行期写口保持仲裁器收敛出的唯一功能写口。消除 v2/v5 双写阻碍。
2. **两读口分配给 BRAM**：A 口写、B 口读给 CPU 主读；第二读口给 eng 旁路搬运（v3 已验证双同步读可进块 RAM）。
3. **ctrl / dbg 配置调试口移出主数组**：命令块参数/状态镜像容量小、访问不频繁，按 4a §7.2 走 LUTRAM / 寄存器副本，或在装载期分时复用主读口；不占 BRAM 读口。消除 v4 组合读阻碍、规避 v6 超读口容量。
4. **若端口收敛后仍需多口**：走 4a §7.4 路径 B，显例化 Gowin 块 RAM 原语（先定单口/双口、位宽、字节使能与只读口档位），而不是依赖行为数组推断；多口需求超出双口时按复制存储或分布式 RAM 兜底评估。

## 6. 产物与复现口径

- 现状综合：`work/regress/synth-gowin-core-top2/core_top_run.log`（IF0008 63488 DFF）。
- 探针源码：`work/regress/ram-probe/probe_v{1,2,3,4,5,6}_*.v`。
- 探针综合产物：`work/regress/ram-probe/probe-v{1,2,3,4,5,6}/`，含 `*_run.log`、成功例另有 `*_syn_rsc.xml`、`*_syn_resource.html`、`*_result.json`。
- 复现命令（pwsh，PATH 前置 Git usr/bin / w64devkit / oss-cad-suite，`PYTHONUTF8=1`）：
  ```
  python <gowin-toolchain>/scripts/synth.py --src <probe>.v --top <probe_top> `
      --pn GW1NSR-LV4CQN48PC6/I5 --outdir <probe-dir>
  ```
- 资源口径：`*_syn_rsc.xml` 的 `T_Bsram` / `T_Lut` / `T_Register` 总计；BSRAM 利用率分母取器件报告 `bsram_total=10`。

## 7. 遗留与待拍板

- ctrl/dbg 口移出主数组的具体方案（LUTRAM 副本 vs 分时复用主读口）、dbg 调试写在硬件形态下的预填通路，留待端口收敛阶段（4a §7.2）定。
- 显例化 Gowin BSRAM 原语的端口名、宽深档位、单/双口类型，待综合网表或原语手册确认（本机帮助文档为编译 qch，未解出）。
- 本次复核未取 Fmax / Logic Level：探针无 SDC 时钟约束，且综合在 RAM 推断阶段即失败；时序与利用率待端口收敛、综合越过推断阶段后再出。
