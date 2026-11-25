/**
 * copy_engine RTL 自检 testbench（Icarus iverilog/vvp）
 *
 * 内置同步 RAM 模型（组合读、时钟写），激励覆盖：
 *   E1 单块装载落位 + 握手回 IDLE
 *   E2 源越界 -> SRC_OOB，目的区哨兵未写
 *   E3 目的越界 -> DST_OOB
 *   E4 零长度   -> ZERO_LEN
 *   E5 握手后复装成功
 *   F1 重叠·目的在源低侧（D<S）：正向复制，目的区落源快照值
 *   F2 重叠·目的在源高侧（D>S 重叠）：反向复制，目的区落源快照值
 *
 * 判据全部内置：PASS/FAIL 逐条打印，结束汇总 RESULT。
 */

`timescale 1ns/1ps

module tb_copy_engine;

    localparam integer MEM_SIZE = 4096;

    // ---- 时钟 / 复位 ----
    reg clk;
    reg resetn;

    // ---- 命令 ----
    reg  [11:0] cmd_src;
    reg  [11:0] cmd_dst;
    reg  [11:0] cmd_len;
    reg         cmd_go;

    // ---- RAM 读口 ----
    wire [11:0] rd_addr;
    wire        rd_req;
    wire [30:0] rd_data;

    // ---- RAM 写口 ----
    wire [11:0] wr_addr;
    wire [30:0] wr_data;
    wire        wr_req;

    // ---- 握手 ----
    reg         ack_done;
    reg         ack_err;

    // ---- 状态 ----
    wire        busy;
    wire        done;
    wire        err;
    wire [1:0]  err_code;
    wire [2:0]  state;
    wire [11:0] remain;

    // ---- 同步 RAM 模型（同步读，一拍延迟，对齐 BRAM 口径） ----
    reg [30:0] ram [0:MEM_SIZE-1];
    reg [30:0] snap [0:3];   // 重叠用例：搬运前源值快照（搬运后源区被改写，不可回读）
    reg [30:0] rd_data_r;
    always @(posedge clk) rd_data_r <= ram[rd_addr];
    assign rd_data = rd_data_r;
    always @(posedge clk) begin
        if (wr_req) ram[wr_addr] <= wr_data;
    end

    // ---- 被测引擎 ----
    copy_engine #(.MEM_SIZE(MEM_SIZE)) u_ce (
        .clk       (clk),
        .resetn    (resetn),
        .cmd_src   (cmd_src),
        .cmd_dst   (cmd_dst),
        .cmd_len   (cmd_len),
        .cmd_go    (cmd_go),
        .rd_addr   (rd_addr),
        .rd_req    (rd_req),
        .rd_data   (rd_data),
        .wr_addr   (wr_addr),
        .wr_data   (wr_data),
        .wr_req    (wr_req),
        .ack_done  (ack_done),
        .ack_err   (ack_err),
        .busy      (busy),
        .done      (done),
        .err       (err),
        .err_code  (err_code),
        .state     (state),
        .remain    (remain)
    );

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- 判据计数 ----
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

    // ---- 下发装载命令 ----
    task launch;
        input [11:0] s;
        input [11:0] d;
        input [11:0] l;
        begin
            cmd_src  = s;
            cmd_dst  = d;
            cmd_len  = l;
            cmd_go   = 1'b1;
            @(posedge clk);
            #1;
            cmd_go   = 1'b0;
        end
    endtask

    // ---- 等待 done/err，带回超时标志 ----
    task wait_finish;
        output timed_out;
        integer cyc;
        begin
            timed_out = 0;
            cyc = 0;
            while (!done && !err && cyc < 1000) begin
                @(posedge clk);
                #1;
                cyc = cyc + 1;
            end
            if (cyc >= 1000) timed_out = 1;
        end
    endtask

    integer i;
    integer timed_out;

    initial begin
        // 初始电平
        resetn   = 1'b0;
        cmd_src  = 12'd0;
        cmd_dst  = 12'd0;
        cmd_len  = 12'd0;
        cmd_go   = 1'b0;
        ack_done = 1'b0;
        ack_err  = 1'b0;
        checks   = 0;
        fails    = 0;

        // 清空 RAM
        for (i = 0; i < MEM_SIZE; i = i + 1) ram[i] = 31'd0;

        // 释放复位
        repeat (4) @(posedge clk);
        resetn = 1'b1;
        @(posedge clk);
        #1;

        // ============ E1 单块装载 ============
        $display("--- E1 single block copy ---");
        for (i = 0; i < 5; i = i + 1) ram[100+i] = 31'h0100_0000 + i;
        for (i = 0; i < 6; i = i + 1) ram[200+i] = 31'h7FFF_FFFF; // 目的区+哨兵

        launch(12'd100, 12'd200, 12'd5);
        wait_finish(timed_out);

        check(!timed_out, "E1 no timeout");
        check(done === 1'b1, "E1 done set");
        check(err  === 1'b0, "E1 err clear");
        check(busy === 1'b0, "E1 busy clear");
        check(remain === 12'd0, "E1 remain zero");

        for (i = 0; i < 5; i = i + 1)
            check(ram[200+i] === ram[100+i], "E1 word copied");
        check(ram[205] === 31'h7FFF_FFFF, "E1 tail sentinel untouched");

        // 完成握手 -> 回 IDLE
        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;
        check(state === 3'd0, "E1 back to IDLE after ack");
        check(done === 1'b0, "E1 done cleared after ack");

        // ============ E2 源越界 ============
        $display("--- E2 source out of bounds ---");
        for (i = 0; i < 10; i = i + 1) ram[300+i] = 31'h7FFF_FFFF;
        launch(12'd4090, 12'd300, 12'd10);
        wait_finish(timed_out);

        check(!timed_out, "E2 no timeout");
        check(err === 1'b1, "E2 err set");
        check(err_code === 2'd1, "E2 err_code SRC_OOB");
        check(busy === 1'b0, "E2 busy clear");
        for (i = 0; i < 10; i = i + 1)
            check(ram[300+i] === 31'h7FFF_FFFF, "E2 dst sentinel untouched");

        ack_err = 1'b1;
        @(posedge clk); #1;
        ack_err = 1'b0;
        check(state === 3'd0, "E2 back to IDLE after ack");

        // ============ E3 目的越界 ============
        $display("--- E3 destination out of bounds ---");
        launch(12'd100, 12'd4090, 12'd10);
        wait_finish(timed_out);

        check(!timed_out, "E3 no timeout");
        check(err === 1'b1, "E3 err set");
        check(err_code === 2'd2, "E3 err_code DST_OOB");

        ack_err = 1'b1;
        @(posedge clk); #1;
        ack_err = 1'b0;

        // ============ E4 零长度 ============
        $display("--- E4 zero length ---");
        launch(12'd100, 12'd200, 12'd0);
        wait_finish(timed_out);

        check(!timed_out, "E4 no timeout");
        check(err === 1'b1, "E4 err set");
        check(err_code === 2'd3, "E4 err_code ZERO_LEN");

        ack_err = 1'b1;
        @(posedge clk); #1;
        ack_err = 1'b0;

        // ============ E5 握手后复装 ============
        $display("--- E5 reload after handshake ---");
        for (i = 0; i < 2; i = i + 1) ram[100+i] = 31'h0200_0000 + i;
        for (i = 0; i < 2; i = i + 1) ram[210+i] = 31'h7FFF_FFFF;
        launch(12'd100, 12'd210, 12'd2);
        wait_finish(timed_out);

        check(!timed_out, "E5 no timeout");
        check(done === 1'b1, "E5 done set");
        check(err === 1'b0, "E5 err clear");
        for (i = 0; i < 2; i = i + 1)
            check(ram[210+i] === ram[100+i], "E5 word copied");

        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;

        // ============ F1 重叠·目的在源低侧（D<S）：正向复制 ============
        $display("--- F1 overlap dst below src (forward) ---");
        for (i = 0; i < 4; i = i + 1) begin
            ram[200+i] = 31'h2000_0000 + i;
            snap[i]     = ram[200+i];
        end
        // 目的区独有部分（198/199）填哨兵；200/201 属源区，保留源值不覆盖
        ram[198] = 31'h7FFF_FFFF;
        ram[199] = 31'h7FFF_FFFF;

        launch(12'd200, 12'd198, 12'd4);
        wait_finish(timed_out);

        check(!timed_out, "F1 no timeout");
        check(done === 1'b1, "F1 done set");
        check(err  === 1'b0, "F1 err clear");
        for (i = 0; i < 4; i = i + 1)
            check(ram[198+i] === snap[i], "F1 forward overlap word");

        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;

        // ============ F2 重叠·目的在源高侧（D>S，重叠）：反向复制 ============
        $display("--- F2 overlap dst above src (reverse) ---");
        for (i = 0; i < 4; i = i + 1) begin
            ram[300+i] = 31'h3000_0000 + i;
            snap[i]     = ram[300+i];
        end
        // 目的区独有部分（304/305）填哨兵；302/303 属源区，保留源值不覆盖
        ram[304] = 31'h7FFF_FFFF;
        ram[305] = 31'h7FFF_FFFF;

        launch(12'd300, 12'd302, 12'd4);
        wait_finish(timed_out);

        check(!timed_out, "F2 no timeout");
        check(done === 1'b1, "F2 done set");
        check(err  === 1'b0, "F2 err clear");
        for (i = 0; i < 4; i = i + 1)
            check(ram[302+i] === snap[i], "F2 reverse overlap word");

        ack_done = 1'b1;
        @(posedge clk); #1;
        ack_done = 1'b0;

        // ---- 汇总 ----
        $display("checks: %0d  failures: %0d", checks, fails);
        if (fails == 0) $display("RESULT: PASS");
        else            $display("RESULT: FAIL");
        $finish;
    end

    // 超时兜底（防死锁）
    initial begin
        #100000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
