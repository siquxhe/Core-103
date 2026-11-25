# 4i · L3-b 固件命令块握手闭环与校验和口径统一

> 范围：在 4h（装载器 + 固件叠加启动路线方案）与 L3-a（loader 灌镜像 → 联锁 → 核心启动最小程序）之后，打通叠加路线后半段——固件运行期主动写命令块、轮询 DONE、写 ACK，引擎搬运握手闭环。
> 本文为落地记录；所列判据、镜像编排、回归数字均来自本轮正本仿真第一手结果。
> 关联文档：4h（叠加路线方案与 L3 验收口径）、4g（引擎子系统装配与背靠背加压）、4f（镜像目录与校验链路）。

## 一、L3-a / L3-b 分界与本轮结果

| 段 | 目标 | 装配 | 结果 |
|---|---|---|---|
| L3-a | loader 灌程序/常量/数据镜像 → 联锁等 `loader_done` → 面板预置入口 → 核心跑最小加法 | `image_loader` + `core_top`（未接引擎） | `LOADER-CORE PASS=3 FAIL=0`，停机回读 3001/3002=7 |
| **L3-b** | 在 L3-a 基础上接回 `engine_ctrl` / `copy_engine`；固件经 PU 写口发命令块，轮询完成、写 ACK，引擎回 IDLE、镜像自清 | `image_loader` + `core_top` + `engine_ctrl` + `copy_engine` + 写仲裁 | `LOADER-FW PASS=7 FAIL=0`，端到端闭环 |

**L3-b 端到端时序**（对齐 4h §4）：

```
loader WIPE → LOAD(程序 0000 / 常量 2000 / 数据 1000) → CHECK 校验和 → loader_done
        │ loader_err=0 门控
        ▼
  面板 arr_strt 预置 entry=0000 → 释放核心复位
        ▼
  固件: 05 SRC=1000→2400, DST=3000→2401, LEN=3→2402, GO=1→2403
        ▼
  ctrl 装配 → copy_engine 搬运 1000→3000（3 字）
        ▼
  固件轮询 2405 DONE=1 → 05 写 2407 ACK → ctrl 自清 → 引擎回 IDLE
        ▼
  核心停机（op=54）
```

## 二、L3-b 镜像编排（八进制）

段定义（`fw_l3b.seg`）：

| 段 | 类型 | 目的地址 | 起 → 止 |
|---|---|---|---|
| 程序段 | 0 | `0000` | `0000..0011` |
| 常量段 | 1 | `2000` | `2000..2005` |
| 源数据段 | 1 | `1000` | `1000..1002` |

程序（`fw_l3b.103`）：

| 地址 | 指令 | 注释 |
|---|---|---|
| `0000` | `05 2003 2400` | SRC = 1000 |
| `0001` | `05 2004 2401` | DST = 3000 |
| `0002` | `05 2005 2402` | LEN = 3 |
| `0003` | `05 2001 2403` | GO = 1 |
| `0004` | `05 2405 2000` | b = mem[DONE] |
| `0005` | `01 2001 2000` | 差值 = b − 1 |
| `0006` | `05 2000 2002` | 差值暂存 |
| `0007` | `34 0004 0010` | 负 → 回 `0004` 轮询；非负 → `0010` |
| `0010` | `05 2001 2407` | ACK = 1 |
| `0011` | `54 0000 0000` | 停机 |

常量：`2000=0, 2001=1, 2002=0, 2003=1000, 2004=3000, 2005=3`；源数据 `1000=3, 1001=4, 1002=5`。

**判据（7 项）**：`entry=0000`；目的区 `3000/3001/3002 = 3/4/5`；引擎回 `IDLE`（state=0）；ACK 镜像自清=0；DONE 镜像自清=0；核心停机。

## 三、卡点根因：校验和累加掩码口径分裂

### 3.1 现象

L3-b 首次仿真在 loader 校验阶段即退出：`loader error code=10`（校验和不符），核心未执行。既有 04_and 镜像累加和未溢出到 bit30，该缺陷此前未暴露；L3-b 镜像字数多、数值大，累加和进入 bit30 后两侧口径分歧显现。

### 3.2 三方实装复核

| 侧 | 位置 | 累加掩码 | 口径 |
|---|---|---|---|
| 打包器 | `tape-converter/src_imagepack/main.c` | `IMG_VALUE_MASK = 0x3fffffff`（30 位） | mod 2^30 |
| simulator 装载侧 | `simulator/src_c/103.c` | `IMG_VALUE_MASK = 0x3fffffff`（30 位） | mod 2^30 |
| RTL loader | `rtl/image_loader.v` | `31'h7fffffff`（31 位） | mod 2^31 |

`image_format.h` 注释写明"累加后 mod 2^31"，与实装的 30 位数值域掩码存在出入。复算 L3-b 镜像：打包尾字按 30 位口径为 `0x38238440`，按 loader 的 31 位口径为 `0x78238440`（bit30=1），二者不等 → code 10。

### 3.3 统一决策

**统一到 mod 2^31（`0x7fffffff`）**，与头文件注释及 RTL loader 实装一致：

- 校验和是 31 位空间（bit30 符号位参与累加，bit31 预留恒 0）；30 位掩码在累加溢出 bit30 时丢弃进位，不符合 mod 2^31 语义。
- 在 `image_format.h` 新增专用掩码宏 `IMG_SUM_MASK = 0x7fffffffu`，与数据字数值域掩码 `IMG_VALUE_MASK`（低 30 位）显式区分；`img_sum_word()` 取符号位的口径不变。
- 打包器 `main.c` 与 simulator `103.c` 的累加/复核掩码由 `IMG_VALUE_MASK` 改为 `IMG_SUM_MASK`；两份 `image_format.h` 副本（`tape-converter/src_imagepack`、`simulator/src_c`）保持逐字节一致。
- RTL `image_loader.v` 维持 31 位口径，未改动。

## 四、回归证据（全量不回退）

| 回归 | 结果 |
|---|---|
| 镜像装载 `regress-image-loader`（C 正向/报错 + RTL 正向/报错） | PASS 21 / FAIL 0；04_and 基线 MD5 `00a84cb87f46cbab5a2e0f1f73a909d2` 保持 |
| L3-a `run_loader_core.ps1` | `LOADER-CORE PASS=3 FAIL=0` |
| L3-b `run_loader_fw.ps1` | `LOADER-FW PASS=7 FAIL=0` |
| `run_fw_poll` / `run_engine_ctrl` / `run_engine_mem` / `run_engine_backpressure` | 全 PASS（背靠背基线沿用 4g `PASS=154/0`） |
| 内核/指令基线：`run_abs` `run_core_eb` `run_cpu_eng_concur` `run_engine_core` `run_inst_cov` `run_io_cases` `run_move_cov` `run_sub` | 全 PASS |

> 编译产物（`*.vvp/*.vcd/*.log/*.bin/*.hex`、`*.o/*.exe`、综合结果快照）按 gitignore 不入库；入库的是 tb、脚本、固件源（`.103/.seg`）与 RTL/源码改动。

## 五、遗留与下一步

1. **多段背靠背**：本轮为单段搬运（`1000→3000`，len 3）。后续扩展固件逐段 issue/wait/ack 循环，覆盖 4h §6.1 第 3 点的多段背靠背编排。
2. **CPU/引擎同拍争写定向用例**：4h §7.3 已记；背靠背加压主要覆盖引擎侧，CPU 写与引擎写同拍并发的定向用例仍待补。
3. **entry 纯硬件自举（可选）**：首版复用面板 `arr_strt` 预置入口；若要求上电不经面板自举，需在 `start_reg` 复位分支增加 `entry_load` 旁路，触及核心取指链，留待评估（4h §7.1）。
4. **L4 量产综合形态**：剥离 dbg、loader 写口接仲裁 CPU 写主后，按综合变体目录复核整链路资源（4h §6 L4）。

## 六、本轮产物对应

| 产物 | 路径 | 角色 |
|---|---|---|
| `tb_loader_fw.v` | `ip_core/tb/` | L3-b 端到端装配 tb（loader + core + ctrl + engine） |
| `run_loader_fw.ps1` | `ip_core/` | L3-b 回归脚本（image-pack → 编译 → 仿真 → 判据） |
| `fw_l3b.103` / `fw_l3b.seg` | `regress/l3-loader-firmware/` | L3-b 固件源与段定义 |
| `image_format.h`（两份副本） | `tape-converter/src_imagepack`、`simulator/src_c` | 新增 `IMG_SUM_MASK`，校验和口径统一 |
| `main.c` / `103.c` | `tape-converter/src_imagepack`、`simulator/src_c` | 累加/复核掩码改 `IMG_SUM_MASK` |
