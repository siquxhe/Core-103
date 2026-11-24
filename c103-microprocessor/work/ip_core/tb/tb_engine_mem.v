/**
 * 2b 集成 testbench · 引擎旁路 ↔ 共享行为 RAM
 *
 * 聚焦集成点：copy_engine 读写口接到既有 memory 模型的旁路端口，
 * 验证引擎写入目的区的内容进入与 CPU 同一存储数组、逐字落位正确。
 * 本 testbench 不驱动核心状态机；CPU 通路可见性由同一数组保证，
 * 核心从目的区取指执行见后续端到端用例。
 *
 * 判据：
 *  1. 引擎完成搬运（done 握手，无 err）；
 *  2. 目的区 LEN 个字与预填源区逐字一致；
 *  3. 源区内容未被搬运流程改写。
 */

`timescale 1ns/1ps

module tb_engine_mem;

    localparam integer WORDS = 2048;
    localparam integer SRC    = 12'd100;
    localparam integer DST    = 12'd300;
    localparam integer LEN    = 12'd8;

    // ---- 时钟 / 复位 ----
    reg clk;
    reg resetn;

    // ---- memory CPU 通路（本 tb 不驱动，接 0） ----
    reg        mem_read_from_pu, mem_read_from_pnl;
    reg        mem_write_from_io, mem_write_from_pnl;
    reg  [11:0] sel_value_from_sel;
    reg         write_sign_from_ac;
    reg  [29:0] write_data_from_au;
    wire        mem_read_reply_to_pu, mem_read_reply_to_ac;
    wire        mem_write_reply_to_op, mem_write_reply_to_io, mem_reply_to_io;
    wire        read_sign_to_ac;
    wire [29:0] read_data_to_au;

    // ---- 引擎命令 / 握手 ----
    reg  [11:0] cmd_src, cmd_dst, cmd_len;
    reg         cmd_go;
    reg         ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  state;
    wire [11:0] remain;

    // ---- 引擎 ↔ memory 旁路 ----
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;

    // ---- 调试口 ----
    reg         dbg_wr_en;
    reg  [11:0] dbg_wr_addr, dbg_rd_addr;
    reg  [30:0] dbg_wr_data;
    wire [30:0] dbg_rd_data;

    // ---- 写口仲裁观测 ----
    wire        grant_cpu, grant_eng, arb_conflict;
    wire        eng_stall;
    integer     saw_conflict;

    integer i;
    integer pass, fail;

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #1 clk = ~clk;

    // 仲裁冲突锁存：本阶段装载期核心停住，CPU 与引擎不应同拍争写
    always @(posedge clk) begin
        if (arb_conflict) saw_conflict = 1;
    end

    // ---- DUT ----
    memory #(.WORDS(WORDS)) u_mem (
        .clk(clk),
        .resetn(resetn),
        .mem_read_from_pu(mem_read_from_pu),
        .mem_read_from_pnl(mem_read_from_pnl),
        .mem_write_from_io(mem_write_from_io),
        .mem_write_from_pnl(mem_write_from_pnl),
        .mem_read_reply_to_pu(mem_read_reply_to_pu),
        .mem_read_reply_to_ac(mem_read_reply_to_ac),
        .mem_write_reply_to_op(mem_write_reply_to_op),
        .mem_write_reply_to_io(mem_write_reply_to_io),
        .mem_reply_to_io(mem_reply_to_io),
        .sel_value_from_sel(sel_value_from_sel),
        .write_sign_from_ac(write_sign_from_ac),
        .write_data_from_au(write_data_from_au),
        .read_sign_to_ac(read_sign_to_ac),
        .read_data_to_au(read_data_to_au),

        .eng_rd_req(eng_rd_req),
        .eng_rd_addr(eng_rd_addr),
        .eng_rd_data(eng_rd_data),
        .eng_wr_req(eng_wr_req),
        .eng_wr_addr(eng_wr_addr),
        .eng_wr_data(eng_wr_data),

        .dbg_wr_en(dbg_wr_en),
        .dbg_wr_addr(dbg_wr_addr),
        .dbg_wr_data(dbg_wr_data),
        .dbg_rd_addr(dbg_rd_addr),
        .dbg_rd_data(dbg_rd_data),
        .grant_cpu(grant_cpu),
        .grant_eng(grant_eng),
        .arb_conflict(arb_conflict),
        .cpu_stall(),
        .eng_stall(eng_stall)
    );

    copy_engine #(.MEM_SIZE(WORDS)) u_eng (
        .clk(clk),
        .resetn(resetn),
        .cmd_src(cmd_src),
        .cmd_dst(cmd_dst),
        .cmd_len(cmd_len),
        .cmd_go(cmd_go),
        .rd_addr(eng_rd_addr),
        .rd_req(eng_rd_req),
        .rd_data(eng_rd_data),
        .wr_addr(eng_wr_addr),
        .wr_data(eng_wr_data),
        .wr_req(eng_wr_req),
        .wr_stall(eng_stall),
        .ack_done(ack_done),
        .ack_err(ack_err),
        .busy(busy),
        .done(done),
        .err(err),
        .err_code(err_code),
        .state(state),
        .remain(remain)
    );

    // ---- 期望字模式：偶数正、奇数负，低 30 位为 i+1 ----
    function [30:0] expected;
        input integer k;
        reg [29:0] val;
        begin
            val = k + 1;
            expected = {k[0], val};
        end
    endfunction

    initial begin
        // 初始化
        resetn = 1'b0;
        mem_read_from_pu = 0; mem_read_from_pnl = 0;
        mem_write_from_io = 0; mem_write_from_pnl = 0;
        sel_value_from_sel = 12'd0;
        write_sign_from_ac = 1'b0; write_data_from_au = 30'd0;
        cmd_src = 0; cmd_dst = 0; cmd_len = 0; cmd_go = 0;
        ack_done = 0; ack_err = 0;
        dbg_wr_en = 0; dbg_wr_addr = 0; dbg_wr_data = 0; dbg_rd_addr = 0;
        saw_conflict = 0;
        pass = 0; fail = 0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // 1) 调试口预填源区
        for (i = 0; i < LEN; i = i + 1) begin
            dbg_wr_en   = 1'b1;
            dbg_wr_addr = SRC + i;
            dbg_wr_data = expected(i);
            @(negedge clk);
        end
        dbg_wr_en = 1'b0;
        @(negedge clk);

        // 2) 下发搬运命令
        cmd_src  = SRC;
        cmd_dst  = DST;
        cmd_len  = LEN;
        cmd_go   = 1'b1;
        @(negedge clk);
        cmd_go   = 1'b0;

        // 3) 等待完成握手
        wait (done || err);
        if (err) begin
            $display("FAIL: engine reported err_code=%0d", err_code);
            fail = fail + 1;
        end else begin
            $display("engine DONE, remain=%0d", remain);
        end
        @(negedge clk);
        ack_done = 1'b1;
        @(negedge clk);
        ack_done = 1'b0;

        // 4) 比对目的区
        for (i = 0; i < LEN; i = i + 1) begin
            dbg_rd_addr = DST + i;
            @(negedge clk);
            if (dbg_rd_data === expected(i)) begin
                pass = pass + 1;
            end else begin
                $display("FAIL dst[%0d]: got %h, expect %h", DST+i, dbg_rd_data, expected(i));
                fail = fail + 1;
            end
        end

        // 5) 源区未被改写
        for (i = 0; i < LEN; i = i + 1) begin
            dbg_rd_addr = SRC + i;
            @(negedge clk);
            if (dbg_rd_data === expected(i)) begin
                pass = pass + 1;
            end else begin
                $display("FAIL src[%0d] altered: got %h, expect %h", SRC+i, dbg_rd_data, expected(i));
                fail = fail + 1;
            end
        end

        if (saw_conflict == 0) begin pass = pass + 1; end
        else begin fail = fail + 1; $display("FAIL write arbitration conflict seen"); end

        $display("ENGINE-MEM PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) begin
            $display("ENGINE-MEM INTEGRATION PASS");
        end else begin
            $display("ENGINE-MEM INTEGRATION FAIL");
        end
        #10 $finish;
    end

endmodule
