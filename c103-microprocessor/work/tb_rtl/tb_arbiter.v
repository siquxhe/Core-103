/**
 * mem_write_arbiter 自检 testbench（Icarus iverilog/vvp，时序 · 背压队列版）
 *
 * 同步接口约定：请求/地址/数据在时钟沿之间稳定，沿后 #1 采样授权与写口；
 * 请求在锁存沿之后再撤，未授权期间由内部 FIFO 排队保持。
 *
 * 覆盖：
 *   A1 仅引擎单条 -> 直通授权，写口透传引擎，服务后撤销
 *   A2 仅 CPU 单条 -> 直通授权，写口透传 CPU
 *   A3 双方持续双待 -> 轮转交替授权（eng/cpu/eng），conflict 置位
 *   A4 排空后空闲 -> 无授权、无冲突、无写使能
 *   B1 CPU 连续 4 条排队 -> 逐条 FIFO 顺序出队，地址/数据正确，最终排空
 *   B2 双主各 3 条交错入队 -> 轮转出队，双方条目全部出完、不饿死
 *   B3 空队时 full 标志为 0
 *   C1 双主突发填满 CPU 队列 -> full/stall 同位置 1
 *   C2 满队期新请求被拒、队头不覆盖、标记条目不入队不排出
 *   C3 排空后撤消背压，重试请求成功入队并出队
 */

`timescale 1ns/1ps

module tb_arbiter;

    reg         clk;
    reg         resetn;

    reg         cpu_wr_req;
    reg  [11:0] cpu_wr_addr;
    reg  [30:0] cpu_wr_data;
    reg         eng_wr_req;
    reg  [11:0] eng_wr_addr;
    reg  [30:0] eng_wr_data;

    wire        ram_wr_req;
    wire [11:0] ram_wr_addr;
    wire [30:0] ram_wr_data;
    wire        grant_cpu;
    wire        grant_eng;
    wire        conflict;
    wire        cpu_full;
    wire        eng_full;
    wire        cpu_stall;
    wire        eng_stall;

    mem_write_arbiter #(.FIFO_DEPTH(4)) u_arb (
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
        .conflict     (conflict),
        .cpu_full     (cpu_full),
        .eng_full     (eng_full),
        .cpu_stall    (cpu_stall),
        .eng_stall    (eng_stall)
    );

    integer checks;
    integer fails;

    task check;
        input        cond;
        input [511:0] name;  // 64 字符余量：断言标签最长约 46 字符，256 位宽会截断超宽前导
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

    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer i, k;
    integer c_cnt, e_cnt;
    integer marker_seen;
    integer full_hit, drained;
    integer wp_full;

    initial begin
        checks = 0;
        fails  = 0;

        resetn      = 1'b0;
        cpu_wr_req  = 1'b0;
        eng_wr_req  = 1'b0;
        cpu_wr_addr = 12'h000;
        cpu_wr_data = 31'd0;
        eng_wr_addr = 12'h000;
        eng_wr_data = 31'd0;

        repeat (4) @(posedge clk);
        #1 resetn = 1'b1;
        @(posedge clk); #1;

        // ---- A1 仅引擎单条 ----
        $display("--- A1 engine only ---");
        eng_wr_addr = 12'h222;
        eng_wr_data = 31'h222_2222;
        eng_wr_req  = 1'b1;
        @(posedge clk); #1;
        check(grant_eng  === 1'b1,          "A1 grant engine");
        check(grant_cpu  === 1'b0,          "A1 no grant cpu");
        check(conflict   === 1'b0,          "A1 no conflict");
        check(ram_wr_req === 1'b1,          "A1 ram req");
        check(ram_wr_addr  === 12'h222,    "A1 ram addr engine");
        check(ram_wr_data === 31'h222_2222, "A1 ram data engine");
        eng_wr_req = 1'b0;
        @(posedge clk); #1;
        check(ram_wr_req === 1'b0, "A1 ram released after service");

        // ---- A2 仅 CPU 单条 ----
        $display("--- A2 cpu only ---");
        cpu_wr_addr = 12'h111;
        cpu_wr_data = 31'h111_1111;
        cpu_wr_req  = 1'b1;
        @(posedge clk); #1;
        check(grant_cpu  === 1'b1,          "A2 grant cpu");
        check(grant_eng  === 1'b0,          "A2 no grant engine");
        check(conflict   === 1'b0,          "A2 no conflict");
        check(ram_wr_req === 1'b1,          "A2 ram req");
        check(ram_wr_addr  === 12'h111,     "A2 ram addr cpu");
        check(ram_wr_data === 31'h111_1111,  "A2 ram data cpu");
        cpu_wr_req = 1'b0;
        @(posedge clk); #1;
        check(ram_wr_req === 1'b0, "A2 ram released after service");

        // ---- A3 双方持续双待：轮转交替 ----
        $display("--- A3 both request, round robin ---");
        cpu_wr_addr = 12'h111;
        cpu_wr_data = 31'h111_1111;
        eng_wr_addr = 12'h222;
        eng_wr_data = 31'h222_2222;
        cpu_wr_req  = 1'b1;
        eng_wr_req  = 1'b1;
        @(posedge clk); #1;
        check(conflict   === 1'b1, "A3 conflict flagged");
        check(grant_eng  === 1'b1, "A3 first turn engine");
        check(grant_cpu  === 1'b0, "A3 cpu waits first turn");
        @(posedge clk); #1;
        check(grant_cpu  === 1'b1, "A3 second turn cpu");
        check(grant_eng  === 1'b0, "A3 engine waits second turn");
        @(posedge clk); #1;
        check(grant_eng  === 1'b1, "A3 third turn engine");
        check(grant_cpu  === 1'b0, "A3 cpu waits third turn");
        cpu_wr_req = 1'b0;
        eng_wr_req = 1'b0;
        repeat (6) @(posedge clk); #1;

        // ---- A4 排空后空闲 ----
        $display("--- A4 none ---");
        check(ram_wr_req === 1'b0, "A4 no ram req");
        check(grant_cpu  === 1'b0, "A4 no grant cpu");
        check(grant_eng  === 1'b0, "A4 no grant engine");
        check(conflict   === 1'b0, "A4 no conflict");

        // ---- B1 CPU 连续 4 条排队，FIFO 顺序出队 ----
        $display("--- B1 cpu burst queue order ---");
        c_cnt = 0;
        for (i = 0; i < 4; i = i + 1) begin
            cpu_wr_req  = 1'b1;
            cpu_wr_addr = 12'h100 + i;
            cpu_wr_data = 31'h1000 + i;
            @(posedge clk); #1;
            if (grant_cpu) begin
                check(ram_wr_addr  === (12'h100 + c_cnt),  "B1 fifo addr order");
                check(ram_wr_data === (31'h1000 + c_cnt), "B1 fifo data order");
                c_cnt = c_cnt + 1;
            end
        end
        cpu_wr_req = 1'b0;
        for (k = 0; k < 50 && c_cnt < 4; k = k + 1) begin
            @(posedge clk); #1;
            if (grant_cpu) begin
                check(ram_wr_addr  === (12'h100 + c_cnt),  "B1 fifo addr order");
                check(ram_wr_data === (31'h1000 + c_cnt), "B1 fifo data order");
                c_cnt = c_cnt + 1;
            end
        end
        check(c_cnt == 4, "B1 all four drained");
        repeat (2) @(posedge clk); #1;
        check(ram_wr_req === 1'b0, "B1 queue drained");

        // ---- B2 双主各 3 条交错入队，轮转出队不饿死 ----
        $display("--- B2 both burst, no starvation ---");
        c_cnt = 0; e_cnt = 0;
        for (i = 0; i < 3; i = i + 1) begin
            cpu_wr_req  = 1'b1;
            cpu_wr_addr = 12'h200 + i;
            cpu_wr_data = 31'h2000 + i;
            eng_wr_req  = 1'b1;
            eng_wr_addr = 12'h300 + i;
            eng_wr_data = 31'h3000 + i;
            @(posedge clk); #1;
            if (grant_cpu) begin
                check(ram_wr_addr  === (12'h200 + c_cnt), "B2 cpu addr order");
                check(ram_wr_data === (31'h2000 + c_cnt), "B2 cpu data order");
                c_cnt = c_cnt + 1;
            end
            if (grant_eng) begin
                check(ram_wr_addr  === (12'h300 + e_cnt), "B2 eng addr order");
                check(ram_wr_data === (31'h3000 + e_cnt), "B2 eng data order");
                e_cnt = e_cnt + 1;
            end
        end
        cpu_wr_req = 1'b0;
        eng_wr_req = 1'b0;

        for (k = 0; k < 100 && (c_cnt < 3 || e_cnt < 3); k = k + 1) begin
            @(posedge clk); #1;
            if (grant_cpu) begin
                check(ram_wr_addr  === (12'h200 + c_cnt),  "B2 cpu addr order");
                check(ram_wr_data === (31'h2000 + c_cnt),  "B2 cpu data order");
                c_cnt = c_cnt + 1;
            end
            if (grant_eng) begin
                check(ram_wr_addr  === (12'h300 + e_cnt),  "B2 eng addr order");
                check(ram_wr_data === (31'h3000 + e_cnt),  "B2 eng data order");
                e_cnt = e_cnt + 1;
            end
        end
        check(c_cnt == 3, "B2 cpu all drained");
        check(e_cnt == 3, "B2 eng all drained");
        repeat (2) @(posedge clk); #1;

        // ---- B3 空队 full 标志 ----
        $display("--- B3 empty full flags ---");
        check(cpu_full === 1'b0, "B3 cpu not full when empty");
        check(eng_full === 1'b0, "B3 eng not full when empty");

        // ---- C 组：满队背压定向自检 ----
        $display("--- C fifo full backpressure ---");
        // C0 前置：进入前双队为空
        check(cpu_full === 1'b0, "C0 cpu not full before fill");
        check(eng_full === 1'b0, "C0 eng not full before fill");

        // 双主持续双待突发，CPU 入队速率高于轮转出队速率，直到 CPU 队列填满
        c_cnt = 0; e_cnt = 0; full_hit = 0;
        for (i = 0; i < 40 && !full_hit; i = i + 1) begin
            cpu_wr_req  = 1'b1;
            cpu_wr_addr = 12'h400 + i[11:0];
            cpu_wr_data = 31'h4000 + i;
            eng_wr_req  = 1'b1;
            eng_wr_addr = 12'h500 + i[11:0];
            eng_wr_data = 31'h5000 + i;
            @(posedge clk); #1;
            if (grant_cpu) c_cnt = c_cnt + 1;
            if (grant_eng) e_cnt = e_cnt + 1;
            if (cpu_full === 1'b1) begin
                $display("C cpu full at cycle %0d", i);
                full_hit = 1;
            end
        end

        // C1 满队：full 与 stall 同值置位；记录满队写指针
        check(cpu_full  === 1'b1, "C1 cpu full set");
        check(cpu_stall === 1'b1, "C1 cpu stall asserted");
        wp_full = u_arb.cpu_wp;

        // C2 满队期注入特殊标记请求：入队护栏屏蔽，写指针不增（标记不入队），队头不被覆盖
        cpu_wr_addr = 12'h9FF;
        cpu_wr_data = 31'h3FFF_FFFF;
        @(posedge clk); #1;
        check(u_arb.cpu_wp === wp_full, "C2 rejected marker not enqueued (wp unchanged)");
        if (grant_cpu)
            check(ram_wr_addr !== 12'h9FF, "C2 marker not head (no overwrite)");

        // 排空：撤双方请求，消化全部积压
        cpu_wr_req = 1'b0;
        eng_wr_req = 1'b0;
        marker_seen = 0; drained = 0;
        for (k = 0; k < 100 && !drained; k = k + 1) begin
            @(posedge clk); #1;
            if (grant_cpu && ram_wr_addr === 12'h9FF) marker_seen = 1;
            if (cpu_full === 1'b0 && eng_full === 1'b0 && ram_wr_req === 1'b0) drained = 1;
        end
        check(marker_seen === 0, "C2 rejected marker never drained");
        check(cpu_full === 1'b0, "C2 cpu queue drained");
        check(eng_full === 1'b0, "C2 eng queue drained");

        // C3 排空后重试一条 CPU：单主直通，入队沿同拍授权出队，队头即重试条目
        cpu_wr_addr = 12'h777;
        cpu_wr_data = 31'h7777_7777;
        cpu_wr_req  = 1'b1;
        @(posedge clk); #1;
        check(ram_wr_addr === 12'h777, "C3 retried entry queued and served");
        cpu_wr_req  = 1'b0;
        repeat (2) @(posedge clk); #1;
        check(ram_wr_req === 1'b0, "C3 drained after retry");

        $display("checks: %0d  failures: %0d", checks, fails);
        if (fails == 0) begin
            $display("ARBITER-COV PASS");
            $display("RESULT: PASS");
        end else begin
            $display("ARBITER-COV FAIL");
            $display("RESULT: FAIL");
        end
        $finish;
    end

endmodule
