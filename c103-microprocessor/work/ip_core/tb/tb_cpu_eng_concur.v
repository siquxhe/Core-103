/**
 * 并发集成 testbench · CPU 写主 ↔ 拷贝引擎写主 公平仲裁
 *
 * 在引擎搬运进行期间并发驱动 CPU 写口写独立地址区，验证公平仲裁下：
 *   1. 引擎搬运目的区逐字落位，未被 CPU 写干扰；
 *   2. CPU 并发写全部落数组，不被引擎抢占饿死、不丢字；
 *   3. 源区未被改写；
 *   4. 仲裁授权唯一（同一拍不会双写同一数组口）。
 *
 * 接线与 tb_engine_mem 一致：memory 行为数组 + copy_engine，CPU 通路经
 * memory 既有写口（mem_write_from_io / sel_value / sign+data）驱动。
 */

`timescale 1ns/1ps

module tb_cpu_eng_concur;

    localparam integer WORDS = 2048;
    localparam integer SRC    = 12'd100;
    localparam integer DST    = 12'd300;
    localparam integer CPU_BASE = 12'd500;
    localparam integer LEN    = 12'd8;
    localparam integer CPU_N  = 3;

    // ---- 时钟 / 复位 ----
    reg clk;
    reg resetn;

    // ---- memory CPU 通路 ----
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
    integer     saw_double_grant;

    integer i;
    integer pass, fail;

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #1 clk = ~clk;

    // 授权互斥观测：同一拍 grant_cpu 与 grant_eng 不得同时为 1
    always @(posedge clk) begin
        if (grant_cpu && grant_eng) saw_double_grant = 1;
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
        .arb_conflict(arb_conflict)
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
        .ack_done(ack_done),
        .ack_err(ack_err),
        .busy(busy),
        .done(done),
        .err(err),
        .err_code(err_code),
        .state(state),
        .remain(remain)
    );

    // 源区期望字：偶数正、奇数负，低 30 位为 i+1
    function [30:0] expected_src;
        input integer k;
        reg [29:0] val;
        begin
            val = k + 1;
            expected_src = {k[0], val};
        end
    endfunction

    // CPU 并发写期望字：正小值，低 30 位为 0x100 + i
    function [30:0] expected_cpu;
        input integer k;
        begin
            expected_cpu = {1'b0, (29'h100 + k)};
        end
    endfunction

    // 驱动一次 CPU 写并等待 reply（写落数组后回送），带超时保护
    task cpu_write;
        input [11:0] a;
        input [30:0] d;
        integer k;
        begin
            sel_value_from_sel  = a;
            write_sign_from_ac  = d[30];
            write_data_from_au  = d[29:0];
            mem_write_from_io   = 1'b1;
            @(negedge clk);
            mem_write_from_io    = 1'b0;
            k = 0;
            while (!mem_write_reply_to_io && k < 500) begin
                @(negedge clk);
                k = k + 1;
            end
            if (k >= 500) begin
                $display("FAIL cpu write timeout addr=%h", a);
                fail = fail + 1;
            end
        end
    endtask

    initial begin
        resetn = 1'b0;
        mem_read_from_pu = 0; mem_read_from_pnl = 0;
        mem_write_from_io = 0; mem_write_from_pnl = 0;
        sel_value_from_sel = 12'd0;
        write_sign_from_ac = 1'b0; write_data_from_au = 30'd0;
        cmd_src = 0; cmd_dst = 0; cmd_len = 0; cmd_go = 0;
        ack_done = 0; ack_err = 0;
        dbg_wr_en = 0; dbg_wr_addr = 0; dbg_wr_data = 0; dbg_rd_addr = 0;
        saw_double_grant = 0;
        pass = 0; fail = 0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // 1) 调试口预填源区
        for (i = 0; i < LEN; i = i + 1) begin
            dbg_wr_en   = 1'b1;
            dbg_wr_addr = SRC + i;
            dbg_wr_data = expected_src(i);
            @(negedge clk);
        end
        dbg_wr_en = 1'b0;
        @(negedge clk);

        // 2) 启动引擎搬运
        cmd_src  = SRC;
        cmd_dst  = DST;
        cmd_len  = LEN;
        cmd_go   = 1'b1;
        @(negedge clk);
        cmd_go   = 1'b0;

        // 3) 搬运进行中并发发起 CPU 写（与引擎写主竞争同一仲裁口）
        for (i = 0; i < CPU_N; i = i + 1) begin
            cpu_write(CPU_BASE + i, expected_cpu(i));
        end

        // 4) 等待引擎完成握手
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

        // 5) 目的区逐字等于源区（引擎搬运未被 CPU 干扰）
        for (i = 0; i < LEN; i = i + 1) begin
            dbg_rd_addr = DST + i;
            @(negedge clk);
            if (dbg_rd_data === expected_src(i)) pass = pass + 1;
            else begin
                $display("FAIL dst[%0d]: got %h, expect %h", DST+i, dbg_rd_data, expected_src(i));
                fail = fail + 1;
            end
        end

        // 6) CPU 并发写全部落数组（未被饿死、未丢字）
        for (i = 0; i < CPU_N; i = i + 1) begin
            dbg_rd_addr = CPU_BASE + i;
            @(negedge clk);
            if (dbg_rd_data === expected_cpu(i)) pass = pass + 1;
            else begin
                $display("FAIL cpu[%0d]: got %h, expect %h", CPU_BASE+i, dbg_rd_data, expected_cpu(i));
                fail = fail + 1;
            end
        end

        // 7) 源区未被改写
        for (i = 0; i < LEN; i = i + 1) begin
            dbg_rd_addr = SRC + i;
            @(negedge clk);
            if (dbg_rd_data === expected_src(i)) pass = pass + 1;
            else begin
                $display("FAIL src[%0d] altered: got %h, expect %h", SRC+i, dbg_rd_data, expected_src(i));
                fail = fail + 1;
            end
        end

        // 8) 授权互斥：全程无双授权
        if (saw_double_grant == 0) pass = pass + 1;
        else begin fail = fail + 1; $display("FAIL double grant seen"); end

        $display("CPU-ENG CONCUR PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) begin
            $display("CPU-ENG CONCURRENCY PASS");
            $display("RESULT: PASS");
        end else begin
            $display("CPU-ENG CONCURRENCY FAIL");
            $display("RESULT: FAIL");
        end
        #10 $finish;
    end

endmodule
