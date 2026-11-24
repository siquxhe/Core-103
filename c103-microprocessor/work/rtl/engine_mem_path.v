/**
 * 103 复刻 · 引擎 + 内存通路封装（独立 iverilog 闭环）
 *
 * 把拷贝引擎、写口仲裁器与行为 RAM 模型接成一条完整内存通路：
 *
 *   CPU 写主 ──┐
 *               ├─ mem_write_arbiter ──→ RAM 写口
 *   引擎 写主 ──┘
 *
 *   CPU 读主 ──┐
 *               ├─ 读地址 mux ──→ RAM 读口 ──→ 引擎 / CPU 读数据
 *   引擎 读主 ──┘
 *
 * 第一步（通路自检）：CPU 主由 testbench 模拟；装载期核心停住，引擎独占读写口。
 * 第二步接核心时，把 cpu_* 主侧接到 core_top 既有内存口即可，封装内部不改。
 *
 * 时序：RAM 模型第一步为组合读；同步读延迟对齐留待第二步接核心处理。
 */

module engine_mem_path #(
    parameter integer MEM_SIZE = 4096
)(
    input         clk,
    input         resetn,

    // ---- 引擎命令（本阶段 testbench / 面板直驱；指令级触发留后续） ----
    input  [11:0] cmd_src,
    input  [11:0] cmd_dst,
    input  [11:0] cmd_len,
    input         cmd_go,
    input         ack_done,
    input         ack_err,

    // ---- CPU 写主（第一步 testbench 模拟；第二步接 core_top 写口） ----
    input         cpu_wr_req,
    input  [11:0] cpu_wr_addr,
    input  [30:0] cpu_wr_data,

    // ---- CPU 读主（预留；第二步接 core_top 读口） ----
    input         cpu_rd_req,
    input  [11:0] cpu_rd_addr,
    output [30:0] cpu_rd_data,

    // ---- 引擎状态 ----
    output        eng_busy,
    output        eng_done,
    output        eng_err,
    output [1:0]  eng_err_code,
    output [2:0]  eng_state,
    output [11:0] eng_remain,

    // ---- 仲裁指示（自检观测） ----
    output        grant_cpu,
    output        grant_eng,
    output        arb_conflict,
    output        cpu_stall,
    output        eng_stall,

    // ---- 调试口（testbench 预填 / 直读校验） ----
    input         dbg_wr_en,
    input  [11:0] dbg_wr_addr,
    input  [30:0] dbg_wr_data,
    input  [11:0] dbg_rd_addr,
    output [30:0] dbg_rd_data
);

    // ---- 仲裁器连线 ----
    wire        ram_wr_req;
    wire [11:0] ram_wr_addr;
    wire [30:0] ram_wr_data;
    wire        cpu_stall_w;
    wire        eng_stall_w;

    // ---- 引擎读/写口 ----
    wire        eng_rd_req;
    wire [11:0] eng_rd_addr;
    wire [30:0] eng_rd_data;
    wire        eng_wr_req;
    wire [11:0] eng_wr_addr;
    wire [30:0] eng_wr_data;

    // ---- RAM 读地址 mux：引擎优先，CPU 读主预留 ----
    wire [11:0] ram_rd_addr = eng_rd_req ? eng_rd_addr : cpu_rd_addr;
    wire [30:0] ram_rd_data;

    mem_write_arbiter u_arb (
        .clk          (clk),
        .resetn       (resetn),
        .cpu_wr_req   (cpu_wr_req),
        .cpu_wr_addr  (cpu_wr_addr),
        .cpu_wr_data  (cpu_wr_data),
        .eng_wr_req   (eng_wr_req),
        .eng_wr_addr  (eng_wr_addr),
        .eng_wr_data  (eng_wr_data),
        .ram_wr_req   (ram_wr_req),
        .ram_wr_addr  (ram_wr_addr),
        .ram_wr_data  (ram_wr_data),
        .grant_cpu    (grant_cpu),
        .grant_eng    (grant_eng),
        .conflict     (arb_conflict),
        .cpu_full      (),
        .eng_full      (),
        .cpu_stall     (cpu_stall_w),
        .eng_stall     (eng_stall_w)
    );

    copy_engine #(.MEM_SIZE(MEM_SIZE)) u_ce (
        .clk       (clk),
        .resetn    (resetn),
        .cmd_src   (cmd_src),
        .cmd_dst   (cmd_dst),
        .cmd_len   (cmd_len),
        .cmd_go    (cmd_go),
        .rd_addr   (eng_rd_addr),
        .rd_req    (eng_rd_req),
        .rd_data   (eng_rd_data),
        .wr_addr   (eng_wr_addr),
        .wr_data   (eng_wr_data),
        .wr_req    (eng_wr_req),
        .wr_stall  (eng_stall_w),
        .ack_done  (ack_done),
        .ack_err   (ack_err),
        .busy      (eng_busy),
        .done      (eng_done),
        .err       (eng_err),
        .err_code  (eng_err_code),
        .state     (eng_state),
        .remain    (eng_remain)
    );

    mem_ram_model #(.WORDS(MEM_SIZE)) u_ram (
        .clk          (clk),
        .resetn       (resetn),
        .wr_en        (ram_wr_req),
        .wr_addr      (ram_wr_addr),
        .wr_data      (ram_wr_data),
        .rd_addr      (ram_rd_addr),
        .rd_data      (ram_rd_data),
        .dbg_wr_en    (dbg_wr_en),
        .dbg_wr_addr  (dbg_wr_addr),
        .dbg_wr_data  (dbg_wr_data),
        .dbg_rd_addr  (dbg_rd_addr),
        .dbg_rd_data  (dbg_rd_data)
    );

    assign eng_rd_data = ram_rd_data;
    assign cpu_rd_data = ram_rd_data;

    assign cpu_stall = cpu_stall_w;
    assign eng_stall = eng_stall_w;

endmodule
