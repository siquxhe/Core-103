/**
 * 103 复刻 · 引擎子系统完整装配 wrapper（综合统计顶层）
 *
 * 装配对象：共享 RAM（memory，含写仲裁器）+ 命令块装配模块（engine_ctrl）
 *           + 拷贝引擎（copy_engine）。不含内核 arith / IO / 译码通路。
 *
 * 连线口径（对齐既有 tb_engine_ctrl 装配关系）：
 *   - eng 旁路读/写：copy_engine ↔ memory；
 *   - ctrl 命令块旁路：engine_ctrl ↔ memory；
 *   - 命令块本地寄存器：memory.cmd_wr_* → engine_ctrl.local_wr_*；
 *   - 引擎背压：memory.eng_stall → copy_engine.wr_stall（补齐既有 tb 悬空缺口）；
 *   - memory CPU 主读写口在子系统内不接内核，输入 tie 0；
 *   - dbg 调试口在量产/综合形态 tie 0，不参与装配（仿真预填走 image_loader）。
 *
 * 本顶层仅用于 Gowin 综合资源统计；行为仿真回归仍走正本 memory.v + 既有 tb。
 */

`timescale 1ns / 1ps

module engine_subsys_wrapper #(
    parameter integer MEM_WORDS = 2048
)(
    input         clk,
    input         resetn,

    // ---- 命令块参数写入口（量产形态由装载器 / 固件驱动） ----
    input         cmd_wr_en,
    input  [11:0] cmd_wr_addr,
    input  [30:0] cmd_wr_data,

    // ---- 引擎 / 装配状态观测输出 ----
    output        busy,
    output        done,
    output        err,
    output [1:0]  err_code,
    output [2:0]  eng_state,
    output [11:0] remain,

    // ---- 仲裁观测（保活 / 调试） ----
    output        grant_cpu,
    output        grant_eng,
    output        arb_conflict,
    output        cpu_stall,
    output        eng_stall
);

    // ---- 内部总线 ----
    // eng 旁路
    wire         eng_rd_req;
    wire [11:0]  eng_rd_addr;
    wire [30:0]  eng_rd_data;
    wire         eng_wr_req;
    wire [11:0]  eng_wr_addr;
    wire [30:0]  eng_wr_data;

    // ctrl 命令块旁路
    wire         ctrl_rd_req;
    wire [11:0]  ctrl_rd_addr;
    wire [30:0]  ctrl_rd_data;
    wire         ctrl_wr_req;
    wire [11:0]  ctrl_wr_addr;
    wire [30:0]  ctrl_wr_data;

    // 命令块本地寄存器旁路（memory → engine_ctrl）
    wire         mem_cmd_wr_en;
    wire [11:0]  mem_cmd_wr_addr;
    wire [30:0]  mem_cmd_wr_data;

    // 引擎握手
    wire [11:0]  cmd_src, cmd_dst, cmd_len;
    wire         cmd_go;
    wire         ack_done, ack_err;

    // ---- 共享 RAM（含写仲裁器） ----
    memory #(.WORDS(MEM_WORDS)) u_mem (
        .clk                    (clk),
        .resetn                 (resetn),

        // CPU 主读口：子系统内不接内核，tie 0；CPU 写口接外部命令参数写
        // （量产形态由装载器/固件驱动），落主存命令块副本并命中后透传本地寄存器。
        .mem_read_from_pu       (1'b0),
        .mem_read_from_pnl      (1'b0),
        .mem_write_from_io      (cmd_wr_en),
        .mem_write_from_pnl     (1'b0),
        .mem_read_reply_to_pu   (),
        .mem_read_reply_to_ac   (),
        .mem_write_reply_to_op  (),
        .mem_write_reply_to_io  (),
        .mem_reply_to_io        (),

        .sel_value_from_sel     (cmd_wr_addr),

        .write_sign_from_ac     (cmd_wr_data[30]),
        .write_data_from_au     (cmd_wr_data[29:0]),
        .read_sign_to_ac        (),
        .read_data_to_au        (),

        // eng 旁路
        .eng_rd_req             (eng_rd_req),
        .eng_rd_addr            (eng_rd_addr),
        .eng_rd_data            (eng_rd_data),
        .eng_wr_req             (eng_wr_req),
        .eng_wr_addr            (eng_wr_addr),
        .eng_wr_data            (eng_wr_data),

        // ctrl 旁路
        .ctrl_rd_req            (ctrl_rd_req),
        .ctrl_rd_addr           (ctrl_rd_addr),
        .ctrl_rd_data           (ctrl_rd_data),
        .ctrl_wr_req            (ctrl_wr_req),
        .ctrl_wr_addr           (ctrl_wr_addr),
        .ctrl_wr_data           (ctrl_wr_data),

        // dbg 调试口：量产/综合形态 tie 0
        .dbg_wr_en              (1'b0),
        .dbg_wr_addr            (12'b0),
        .dbg_wr_data            (31'b0),
        .dbg_rd_addr            (12'b0),
        .dbg_rd_data            (),

        // 仲裁观测
        .grant_cpu              (grant_cpu),
        .grant_eng              (grant_eng),
        .arb_conflict           (arb_conflict),
        .cpu_stall              (cpu_stall),
        .eng_stall              (eng_stall),

        // 命令块写旁路
        .cmd_wr_en              (mem_cmd_wr_en),
        .cmd_wr_addr            (mem_cmd_wr_addr),
        .cmd_wr_data            (mem_cmd_wr_data)
    );

    // ---- 拷贝引擎 ----
    copy_engine #(.MEM_SIZE(MEM_WORDS)) u_eng (
        .clk            (clk),
        .resetn         (resetn),
        .cmd_src        (cmd_src),
        .cmd_dst        (cmd_dst),
        .cmd_len        (cmd_len),
        .cmd_go         (cmd_go),
        .rd_addr        (eng_rd_addr),
        .rd_req         (eng_rd_req),
        .rd_data        (eng_rd_data),
        .wr_addr        (eng_wr_addr),
        .wr_data        (eng_wr_data),
        .wr_req         (eng_wr_req),
        .wr_stall       (eng_stall),
        .ack_done       (ack_done),
        .ack_err        (ack_err),
        .busy           (busy),
        .done           (done),
        .err            (err),
        .err_code       (err_code),
        .state          (eng_state),
        .remain         (remain)
    );

    // ---- 命令块装配模块 ----
    engine_ctrl u_ctrl (
        .clk            (clk),
        .resetn         (resetn),
        .ctrl_rd_req    (ctrl_rd_req),
        .ctrl_rd_addr   (ctrl_rd_addr),
        .ctrl_rd_data   (ctrl_rd_data),
        .ctrl_wr_req    (ctrl_wr_req),
        .ctrl_wr_addr   (ctrl_wr_addr),
        .ctrl_wr_data   (ctrl_wr_data),
        .local_wr_en    (mem_cmd_wr_en),
        .local_wr_addr  (mem_cmd_wr_addr),
        .local_wr_data  (mem_cmd_wr_data),
        .cmd_src        (cmd_src),
        .cmd_dst        (cmd_dst),
        .cmd_len        (cmd_len),
        .cmd_go         (cmd_go),
        .ack_done       (ack_done),
        .ack_err        (ack_err),
        .busy           (busy),
        .done           (done),
        .err            (err),
        .err_code       (err_code)
    );

endmodule
