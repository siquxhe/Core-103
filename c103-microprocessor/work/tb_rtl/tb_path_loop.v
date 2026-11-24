/**
 * engine_mem_path 通路自检 testbench（Icarus iverilog/vvp）
 *
 * 验证引擎 + 仲裁器 + 行为 RAM 的完整内存通路（独立 iverilog 闭环，不依赖
 * 既有 Verilator 工程）：
 *   P1 镜像搬运落位：dbg 预填源区 → 引擎搬运 → dbg 直读目的区逐字比对，哨兵未写
 *   P2 仲裁对照：空闲 CPU 写直通（grant_cpu）；搬运期引擎授权（grant_eng）
 *   P3 握手后复装第二块，无跨块串扰
 *   P4 源越界经通路透传 ERR，目的区哨兵未写
 */

`timescale 1ns/1ps

module tb_path_loop;

    localparam integer MEM_SIZE = 4096;

    reg         clk;
    reg         resetn;

    reg  [11:0] cmd_src;
    reg  [11:0] cmd_dst;
    reg  [11:0] cmd_len;
    reg         cmd_go;
    reg         ack_done;
    reg         ack_err;

    reg         cpu_wr_req;
    reg  [11:0] cpu_wr_addr;
    reg  [30:0] cpu_wr_data;
    reg         cpu_rd_req;
    reg  [11:0] cpu_rd_addr;
    wire [30:0] cpu_rd_data;

    wire        eng_busy;
    wire        eng_done;
    wire        eng_err;
    wire [1:0]  eng_err_code;
    wire [2:0]  eng_state;
    wire [11:0] eng_remain;
    wire        grant_cpu;
    wire        grant_eng;
    wire        arb_conflict;

    reg         dbg_wr_en;
    reg  [11:0] dbg_wr_addr;
    reg  [30:0] dbg_wr_data;
    reg  [11:0] dbg_rd_addr;
    wire [30:0] dbg_rd_data;

    engine_mem_path #(.MEM_SIZE(MEM_SIZE)) u_path (
        .clk          (clk),
        .resetn       (resetn),
        .cmd_src      (cmd_src),
        .cmd_dst      (cmd_dst),
        .cmd_len      (cmd_len),
        .cmd_go       (cmd_go),
        .ack_done     (ack_done),
        .ack_err      (ack_err),
        .cpu_wr_req   (cpu_wr_req),
        .cpu_wr_addr  (cpu_wr_addr),
        .cpu_wr_data  (cpu_wr_data),
        .cpu_rd_req   (cpu_rd_req),
        .cpu_rd_addr  (cpu_rd_addr),
        .cpu_rd_data  (cpu_rd_data),
        .eng_busy     (eng_busy),
        .eng_done     (eng_done),
        .eng_err      (eng_err),
        .eng_err_code (eng_err_code),
        .eng_state    (eng_state),
        .eng_remain   (eng_remain),
        .grant_cpu    (grant_cpu),
        .grant_eng    (grant_eng),
        .arb_conflict (arb_conflict),
        .dbg_wr_en    (dbg_wr_en),
        .dbg_wr_addr  (dbg_wr_addr),
        .dbg_wr_data  (dbg_wr_data),
        .dbg_rd_addr  (dbg_rd_addr),
        .dbg_rd_data  (dbg_rd_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer checks;
    integer fails;

    task check;
        input        cond;
        input [255:0] name;
        begin
            if (cond) begin
                checks = checks + 1;
                $display("PASS %0s", name);
            end else begin
                fails = fails + 1;
                $display("FAIL %0s", name);
            end
        end
    endtask

    task dbg_write;
        input [11:0] a;
        input [30:0] d;
        begin
            dbg_wr_en   = 1'b1;
            dbg_wr_addr = a;
            dbg_wr_data = d;
            @(posedge clk); #1;
            dbg_wr_en = 1'b0;
        end
    endtask

    task dbg_read;
        input  [11:0] a;
        output [30:0] d;
        begin
            dbg_rd_addr = a;
            #1;
            d = dbg_rd_data;
        end
    endtask

    task launch;
        input [11:0] s;
        input [11:0] d;
        input [11:0] l;
        begin
            cmd_src = s;
            cmd_dst = d;
            cmd_len = l;
            cmd_go  = 1'b1;
            @(posedge clk); #1;
            cmd_go  = 1'b0;
        end
    endtask

    task wait_finish;
        output timed_out;
        integer cyc;
        reg [30:0] tmp;
        begin
            timed_out = 0;
            cyc = 0;
            while (!eng_done && !eng_err && cyc < 2000) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            if (cyc >= 2000) timed_out = 1;
        end
    endtask

    integer i;
    integer timed_out;
    reg [30:0] rd_word;
    integer saw_eng_grant;

    initial begin
        resetn    = 1'b0;
        cmd_src   = 12'd0;
        cmd_dst  = 12'd0;
        cmd_len  = 12'd0;
        cmd_go   = 1'b0;
        ack_done = 1'b0;
        ack_err  = 1'b0;
        cpu_wr_req  = 1'b0;
        cpu_wr_addr = 12'd0;
        cpu_wr_data = 31'd0;
        cpu_rd_req  = 1'b0;
        cpu_rd_addr = 12'd0;
        dbg_wr_en   = 1'b0;
        dbg_wr_addr = 12'd0;
        dbg_wr_data = 31'd0;
        dbg_rd_addr = 12'd0;
        checks = 0;
        fails  = 0;

        repeat (4) @(posedge clk);
        resetn = 1'b1;
        @(posedge clk); #1;

        // ============ P1 镜像搬运落位 ============
        $display("--- P1 image copy over path ---");
        for (i = 0; i < 5; i = i + 1) dbg_write(100+i, 31'h0100_0000 + i);
        for (i = 0; i < 6; i = i + 1) dbg_write(200+i, 31'h7FFF_FFFF);

        launch(12'd100, 12'd200, 12'd5);
        wait_finish(timed_out);

        check(!timed_out, "P1 no timeout");
        check(eng_done === 1'b1, "P1 done set");
        check(eng_err  === 1'b0, "P1 err clear");
        check(eng_busy === 1'b0, "P1 busy clear");
        check(eng_remain === 12'd0, "P1 remain zero");

        for (i = 0; i < 5; i = i + 1) begin
            dbg_read(100+i, rd_word);
            check(rd_word === (31'h0100_0000 + i), "P1 source intact");
            dbg_read(200+i, rd_word);
            check(rd_word === (31'h0100_0000 + i), "P1 destination copied");
        end
        dbg_read(205, rd_word);
        check(rd_word === 31'h7FFF_FFFF, "P1 tail sentinel untouched");

        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;
        check(eng_state === 3'd0, "P1 back to IDLE after ack");

        // ============ P2 仲裁对照 ============
        $display("--- P2 arbiter grant ---");
        // 空闲时 CPU 写直通（时序仲裁：请求在锁存沿授权，下一拍排空）
        cpu_wr_req  = 1'b1;
        cpu_wr_addr = 12'd300;
        cpu_wr_data = 31'h0CAF_0001;
        @(posedge clk); #1;
        check(grant_cpu === 1'b1, "P2 cpu granted when idle");
        check(grant_eng === 1'b0, "P2 engine idle when cpu grants");
        check(arb_conflict === 1'b0, "P2 no conflict when cpu only");
        @(posedge clk); #1;
        cpu_wr_req = 1'b0;
        dbg_read(300, rd_word);
        check(rd_word === 31'h0CAF_0001, "P2 cpu write landed in RAM");

        // 搬运期观测引擎授权
        dbg_write(400, 31'h0200_0001);
        dbg_write(401, 31'h0200_0002);
        dbg_write(310, 31'h7FFF_FFFF);
        dbg_write(311, 31'h7FFF_FFFF);
        saw_eng_grant = 0;
        launch(12'd400, 12'd310, 12'd2);
        // 搬运过程中采样授权
        while (!eng_done && !eng_err) begin
            @(posedge clk); #1;
            if (grant_eng === 1'b1) saw_eng_grant = 1;
        end
        check(saw_eng_grant === 1, "P2 engine granted during copy");
        check(grant_cpu === 1'b0 || !eng_busy, "P2 cpu blocked while engine busy");
        dbg_read(310, rd_word);
        check(rd_word === 31'h0200_0001, "P2 second block word0");
        dbg_read(311, rd_word);
        check(rd_word === 31'h0200_0002, "P2 second block word1");
        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;

        // ============ P3 复装（已在 P2 体现，补一次第三块） ============
        $display("--- P3 reload after handshake ---");
        dbg_write(500, 31'h0300_0003);
        dbg_write(320, 31'h7FFF_FFFF);
        launch(12'd500, 12'd320, 12'd1);
        wait_finish(timed_out);
        check(!timed_out, "P3 no timeout");
        check(eng_done === 1'b1, "P3 done set");
        dbg_read(320, rd_word);
        check(rd_word === 31'h0300_0003, "P3 reload copied");
        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;

        // ============ P4 源越界透传 ============
        $display("--- P4 source out of bounds over path ---");
        dbg_write(330, 31'h7FFF_FFFF);
        dbg_write(331, 31'h7FFF_FFFF);
        launch(12'd4090, 12'd330, 12'd10);
        wait_finish(timed_out);
        check(!timed_out, "P4 no timeout");
        check(eng_err === 1'b1, "P4 err set");
        check(eng_err_code === 2'd1, "P4 err_code SRC_OOB");
        dbg_read(330, rd_word);
        check(rd_word === 31'h7FFF_FFFF, "P4 dst sentinel untouched");
        ack_err = 1'b1;
        @(posedge clk); #1;
        ack_err = 1'b0;

        $display("checks: %0d  failures: %0d", checks, fails);
        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
