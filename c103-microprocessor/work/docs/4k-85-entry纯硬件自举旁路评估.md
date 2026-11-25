# 4k · #85 entry 纯硬件自举旁路评估

> 范围：评估"上电不经面板 `arr_strt` 预置入口、由硬件在装载完成后自动把 `loader_entry` 载入起指寄存器"的可行性、改动面、风险与时机。
> 本文为评估记录，不含 RTL 改动；所列事实均来自本轮第一手源码 / tb / 文档核对。
> 关联文档：4h §2.5 / §7.1（entry 两条路径）、4f（镜像目录与装载链路）、4i（L3-b 闭环）、NOTICE（上游归属）。

## 一、调查目的与范围

- **目的**：弄清 entry 入口地址当前如何载入起指寄存器、取指链如何解锁，判断纯硬件自举旁路是否可行、改哪里、风险多大、何时做。
- **读了**：`core/start_reg.v`、`core/core_top.v`、`core/pulse_unit.v`、`core/select_reg.v`、`rtl/image_loader.v`、`tb/tb_loader_fw2.v`；文档 4h/4f/00；simulator `103.c` `set_pc`；仓内 NOTICE。
- **未跑**：本轮为现状核对，未搭新激励、未改 RTL。

## 二、已核实的事实（附来源）

1. **起指寄存器只有三条写入通路，无复位加载外部 entry 的硬件通路。**
   `start_reg`（ПР）复位值 `0`；`if/else if` 链依次为：面板 `do_arr_strt`（`arr_strt_data_from_pnl`）→ PU 递增 `do_inc_strt` → 跳转 `do_sel_to_strt`（`sel_value_from_sel`）。（来源：`start_reg.v:28-38`；4h §2.5 第 75 行）

2. **core_top 未接 loader entry，start_reg 仅连面板 arr_strt。**
   core_top 端口无 `loader_entry` / boot 旁路信号；`do_arr_strt_from_pnl_to_strt`、`arr_strt_data_from_pnl_to_strt` 直接来自 `pnl_do_arr_strt` / `pnl_arr_strt_value`。（来源：`core_top.v:38-39, 351-364, 540-541`）

3. **loader 已稳定产出 entry，与 done 同拍保持。**
   `image_loader` 在 `S_LOAD` 结束拍锁存 `entry_pc → loader_entry` 并置 `loader_done`；`S_DONE` 态不再改写。`loader_entry` 是电平保持量，不是单拍脉冲。（来源：`image_loader.v:209-214, 212`）

4. **取指链时序：start_reg 必须在 start_pulse 之前就绪。**
   PU 在 state 0 等 `start_pulse_from_io`；首个脉冲 `do_strt_to_sel` 把 start_reg 当前值打入 select_reg，select_reg → memory 读地址；随后 `do_inc_strt` 使 PC+1。（来源：`pulse_unit.v:108,119-120,125`；`select_reg.v:39-40`）

5. **当前装配由 tb（面板角色）在装载完成后手动预置 entry。**
   时序：`wait(loader_done || loader_err)` → `core_resetn` 脉冲复位核心 → 面板 `pnl_do_arr_strt` + `pnl_arr_strt_value=loader_entry` 写入 start_reg → `pnl_clear_pu` → `pnl_start_pulse`。loader/引擎/ctrl 复位用 `resetn`，核心复位用 `core_resetn`，是两个复位域。（来源：`tb_loader_fw2.v:210, 230-249`）

6. **C 模拟器对照形态：装载校验通过后直接 `set_pc(entry)`，无面板步骤。**
   `load_image` 成功路径末句 `set_pc((int)entry)`。（来源：`simulator/src_c/103.c:477`；`set_pc` 定义 `103.c:31-33`）

7. **无顶层装配 wrapper；loader 与 core 目前只在 tb 连线。** `work/rtl/` 下无 top 模块。（来源：`work/rtl/*.v` 目录清单）

8. **上游归属约束（NOTICE）。**
   - `start_reg.v`：**原样继承**上游（NOTICE:27）。
   - `core_top.v`：**在上游基础上修改派生**（NOTICE:45）。
   - 即：改 `core_top.v` 符合既有改动模式；改 `start_reg.v` 会把它从"原样继承"变为"修改派生"，需同步更新 NOTICE。

## 三、合理推断（说明推理链）

### 3.1 可行性：中-高

entry 数据通路在 loader 侧已经就绪（事实 3），缺口仅是"在核心首次取指前，把 `loader_entry` 硬件写入 start_reg"这一个写入脉冲。不涉及译码、指令集或数据通路改造。

### 3.2 两条候选落点

| | 方案甲：start_reg 内置复位加载旁路 | 方案乙：顶层联锁复用 arr_strt 通路（推荐） |
|---|---|---|
| 做法 | `start_reg` 增加 `do_boot_strt` + `boot_entry` 输入，在复位释放 / loader_done 有效拍写入；优先级置于 PU 运行期通路之下 | 不改 `start_reg` 内部；在 wrapper / 顶层用 `loader_done && !loader_err` 上升沿生成一个等价 arr_strt 脉冲，把 `loader_entry` 经既有面板通路打入 start_reg；core_top 透传 |
| 侵入件 | 改动 `start_reg.v`（原样继承件 → 需转修改派生并更新 NOTICE） | 仅在 `core_top.v`（已是修改派生件）/ 自研 wrapper 加旁路端口 |
| 与上游一致性 | 破坏原样继承件的字节一致 | 保留 `start_reg.v` 原样 |
| 适用场景 | 要求起指寄存器自带"复位加载外部 entry"能力 | 仅需上电自举、复用既有启动地址写入口 |

**推理链**：事实 8 表明 `start_reg.v` 是原样继承件，改动它有归属成本；事实 1 表明 arr_strt 本就是现成的启动地址写入口；事实 4 表明只要在 start_pulse 前写入即可。因此方案乙以最小侵入达成同一目标。

### 3.3 时序与联锁要点（无论甲乙）

- **写入窗口**：`loader_done=1 且 loader_err=0`、`core_resetn` 释放之后、`start_pulse` 之前。
- **跨复位域**：`loader_done` 在 `resetn` 域，核心在 `core_resetn` 域；entry 为电平保持量可直接跨域采样，但 boot 触发脉冲需打拍同步，避免亚稳态。
- **错误路径门控**：`loader_err=1` 时不得把 entry 写入核心（报错镜像 entry 无意义）。
- **PC 竞争屏蔽**：boot 写入必须是单拍脉冲，或带"已加载"标志屏蔽；不得与运行期 `inc_strt` / `sel_to_strt` 同拍竞争改写 PC。

## 四、未知 / 存疑（需后续确认）

- **双复位域上板是否同源**：tb 分 `resetn` / `core_resetn`，真实上板两者是否同一复位源，待 L4 顶层 wrapper 定型时确认。
- **boot 脉冲与 clear_pu / start_pulse 的确切拍数对齐**：需波形验证（同类时序口径见 4h §7.4）。
- **面板调试入口是否保留**：上板后是否需要"面板可覆盖 boot entry"的仲裁（调试期手动改起始地址），产品形态未定。

## 五、评估结论与建议

- **判断**：纯硬件自举旁路**可行，改动面小**；entry 数据已由 loader 稳定产出，缺的只是硬件写入脉冲接入起指寄存器。置信度：中-高（时序窗口与跨域联锁需上板/波形复核，见第四节）。
- **推荐路径**：**方案乙**——顶层联锁复用 arr_strt 通路，不动 `start_reg.v` 原样继承件；旁路端口加在 `core_top.v` / 自研 wrapper。方案甲仅在后续明确要求起指寄存器自带复位加载能力时再采用。
- **时机：暂缓，归入 L4 量产综合 / 上板形态前置项。** 当前仿真基线维持面板预置已跑通 L3-a/b/c 闭环；无开发板、未跑 P&R，自举旁路在纯仿真阶段不增加功能覆盖。不阻塞主线。
- **改动量预估（落地时）**：core_top / wrapper 增加 2 个旁路端口（`boot_load` 触发、`boot_entry` 数据）；新增一条自举 tb——去掉 `pnl_do_arr_strt` 激励，断言装载完成后 start_reg 自动等于 `loader_entry`，并能自动取指跑通既有固件（复用 `tb_loader_fw2` 判据）。
- **验证出口**：自举 tb 全绿 + 既有 16 条回归不回退；若落地时改了 `start_reg.v`，同步更新 NOTICE 归属分类。

## 六、与既有产物的对应

| 项 | 路径 | 现状角色 |
|---|---|---|
| `start_reg.v` | `ip_core/core/` | 起指寄存器；上游原样继承，三条写入通路 |
| `core_top.v` | `ip_core/core/` | 内核装配顶层；上游修改派生，旁路端口的预期落点 |
| `image_loader.v` | `rtl/` | 产出 `loader_done/err/entry`，entry 电平保持 |
| `tb_loader_fw2.v` | `ip_core/tb/` | 当前面板预置 entry 的装配参照；自举 tb 的判据来源 |
| `NOTICE` | 仓根 | 上游归属分类；落地改 start_reg 时需更新 |
