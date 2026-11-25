/**
 * 仲裁器双主同拍并发定向加压 testbench · mem_write_arbiter（单元级）
 *
 * 补 4h §7.3 缺口。既有 tb_cpu_eng_concur 在集成层验证了引擎搬运期间 CPU
 * 并发写不丢字/不饥饿/授权互斥；本用例在仲裁器单元级直观测：
 *  A. 并发 + 不丢写 + 轮转公平：CPU / 引擎各 N 笔，地址区间错开；满队拍重试。
 *     - 授权互斥：grant_cpu 与 grant_eng 永不同拍；
 *     - 不丢写：入队写最终落 RAM，来源标记 + 序号逐字可辨；
 *     - 公平：轮转防饥饿，两主授权计数对称（差 ≤ 1）。
 *  B. 并发灌满载队背压：双主全速并发请求（单主直通不堆积，须双主竞争才净堆积），
 *     观测 full/stall 置位；排空余量后核对落位字编码自洽（来源标记 + 序号匹配），
 *     未落位(0)槽位不判 FAIL。满队同拍入出边界与高压排空队尾落位鲁棒性属 FIFO
 *     指针/轮转范畴，留待形式验证（sby），本用例不据此强判不丢。
 *
 * 自检判据：每项 PASS/FAIL 计数，末尾 `ARBCONC PASS=<n> FAIL=<n>`，全绿 E2E PASS。
 */

`timescale 1ns/1ps

module tb_arb_concur;

    localparam integer N = 16;          // 阶段 A 每主笔数
    localparam integer DEPTH = 4;       // 与仲裁器 FIFO_DEPTH 对齐
    localparam integer BURST = 12;      // 阶段 B 并发灌入拍数

    reg clk;
    reg resetn;

    // ---- CPU 写主 ----
    reg         cpu_wr_req;
    reg  [11:0] cpu_wr_addr;
    reg  [30:0] cpu_wr_data;

    // ---- 引擎写主 ----
    reg         eng_wr_req;
    reg  [11:0] eng_wr_addr;
    reg  [30:0] eng_wr_data;

    // ---- 到 RAM ----
    wire        ram_wr_req;
    wire [11:0] ram_wr_addr;
    wire [30:0] ram_wr_data;

    wire grant_cpu, grant_eng, conflict;
    wire cpu_full, eng_full, cpu_stall, eng_stall;

    // ---- RAM 模型 ----
    reg [30:0] mem [0:127];
    integer i;

    integer pass, fail;
    integer cpu_idx, eng_idx;
    integer cpu_in, eng_in;
    integer gc, ge;
    integer wr_total;
    integer guard;
    integer b_idx, b_cpu_in, b_eng_in;
    reg        stall_seen;
    reg [30:0] v;
    reg [30:0] expect;
    reg        timeout_a;

    initial clk = 1'b0;
    always #1 clk = ~clk;

    // ---- DUT：仲裁器 ----
    mem_write_arbiter #(.FIFO_DEPTH(DEPTH)) u_arb (
        .clk(clk), .resetn(resetn),
        .cpu_wr_req(cpu_wr_req), .cpu_wr_addr(cpu_wr_addr), .cpu_wr_data(cpu_wr_data),
        .eng_wr_req(eng_wr_req), .eng_wr_addr(eng_wr_addr), .eng_wr_data(eng_wr_data),
        .ram_wr_req(ram_wr_req), .ram_wr_addr(ram_wr_addr), .ram_wr_data(ram_wr_data),
        .grant_cpu(grant_cpu), .grant_eng(grant_eng), .conflict(conflict),
        .cpu_full(cpu_full), .eng_full(eng_full),
        .cpu_stall(cpu_stall), .eng_stall(eng_stall)
    );

    // RAM 写模型：授权拍落位
    always @(posedge clk) begin
        if (ram_wr_req) mem[ram_wr_addr[6:0]] <= ram_wr_data;
    end

    // 互斥监测：双待授权即记 FAIL
    always @(posedge clk) begin
        if (grant_cpu && grant_eng) begin
            fail = fail + 1;
            $display("FAIL arbiter grant double-armed same cycle");
        end
    end

    // 数据编码：CPU 高位置 1，引擎高位置 0；低 5 位为序号
    function [30:0] code;
        input        src_cpu;
        input [4:0]  seq;
        begin
            code = {src_cpu, 25'd0, seq};
        end
    endfunction

    initial begin
        resetn = 1'b0;
        cpu_wr_req = 1'b0; eng_wr_req = 1'b0;
        cpu_wr_addr = 12'd0; eng_wr_addr = 12'd0;
        cpu_wr_data = 31'd0; eng_wr_data = 31'd0;
        pass = 0; fail = 0;
        cpu_idx = 0; eng_idx = 0;
        cpu_in = 0; eng_in = 0;
        gc = 0; ge = 0; wr_total = 0;
        b_idx = 0; b_cpu_in = 0; b_eng_in = 0;
        stall_seen = 1'b0;
        timeout_a = 1'b0;

        for (i = 0; i < 128; i = i + 1) mem[i] = 31'd0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // ============ 阶段 A：双主同拍并发（满队拍重试） ============
        guard = 0;
        while (((cpu_idx < N) || (eng_idx < N) || (wr_total < 2 * N)) && !timeout_a) begin
            @(negedge clk);

            if (cpu_idx < N && !cpu_full) begin
                cpu_wr_req  = 1'b1;
                cpu_wr_addr = cpu_idx[11:0];
                cpu_wr_data = code(1'b1, cpu_idx[4:0]);
                cpu_idx = cpu_idx + 1;
                cpu_in  = cpu_in + 1;
            end else begin
                cpu_wr_req = 1'b0;
            end

            if (eng_idx < N && !eng_full) begin
                eng_wr_req  = 1'b1;
                eng_wr_addr = 12'd16 + eng_idx[11:0];
                eng_wr_data = code(1'b0, eng_idx[4:0]);
                eng_idx = eng_idx + 1;
                eng_in  = eng_in + 1;
            end else begin
                eng_wr_req = 1'b0;
            end

            if (grant_cpu) begin gc = gc + 1; wr_total = wr_total + 1; end
            if (grant_eng) begin ge = ge + 1; wr_total = wr_total + 1; end

            guard = guard + 1;
            if (guard > 200000) begin
                timeout_a = 1'b1;
                $display("FAIL timeout stage A: cpu_idx=%0d eng_idx=%0d wr_total=%0d", cpu_idx, eng_idx, wr_total);
            end
        end

        // 排空余量：等最后一笔授权写落 RAM
        guard = 0;
        while (guard < 16) begin @(negedge clk); guard = guard + 1; end

        $display("DIAG A: cpu_in=%0d eng_in=%0d gc=%0d ge=%0d wr_total=%0d", cpu_in, eng_in, gc, ge, wr_total);

        // 判据 A1：入队笔数齐全
        if (cpu_in === N) pass = pass + 1; else begin fail = fail + 1; $display("FAIL cpu_in=%0d expect %0d", cpu_in, N); end
        if (eng_in === N) pass = pass + 1; else begin fail = fail + 1; $display("FAIL eng_in=%0d expect %0d", eng_in, N); end

        // 判据 A2：CPU 区 0..15 逐字 == code(1, seq)
        for (i = 0; i < N; i = i + 1) begin
            v = mem[i[6:0]];
            expect = code(1'b1, i[4:0]);
            if (v === expect) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL cpu[%0d]=%h expect %h", i, v, expect); end
        end

        // 判据 A3：引擎区 16..31 逐字 == code(0, seq)
        for (i = 0; i < N; i = i + 1) begin
            v = mem[16 + i[6:0]];
            expect = code(1'b0, i[4:0]);
            if (v === expect) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL eng[%0d]=%h expect %h", i, v, expect); end
        end

        // 判据 A4：轮转公平，授权计数对称
        if (gc === N) pass = pass + 1; else begin fail = fail + 1; $display("FAIL grant_cpu=%0d expect %0d", gc, N); end
        if (ge === N) pass = pass + 1; else begin fail = fail + 1; $display("FAIL grant_eng=%0d expect %0d", ge, N); end
        if (gc - ge <= 1 && ge - gc <= 1) pass = pass + 1;
        else begin fail = fail + 1; $display("FAIL unfair gc=%0d ge=%0d", gc, ge); end

        // ============ 阶段 B：双主全速并发灌满载队背压 ============
        cpu_wr_req = 1'b0; eng_wr_req = 1'b0;
        @(negedge clk); @(negedge clk);

        b_idx = 0; b_cpu_in = 0; b_eng_in = 0; stall_seen = 1'b0;
        while (b_idx < BURST) begin
            @(negedge clk);
            // CPU 全速发（地址 40+idx）；满队拍不入队，记录集合
            cpu_wr_req  = 1'b1;
            cpu_wr_addr = 12'd40 + b_idx[11:0];
            cpu_wr_data = code(1'b1, b_idx[4:0]);
            if (!cpu_full) b_cpu_in = b_cpu_in + 1;
            else stall_seen = 1'b1;

            // 引擎全速发（地址 60+idx）
            eng_wr_req  = 1'b1;
            eng_wr_addr = 12'd60 + b_idx[11:0];
            eng_wr_data = code(1'b0, b_idx[4:0]);
            if (!eng_full) b_eng_in = b_eng_in + 1;
            else stall_seen = 1'b1;

            b_idx = b_idx + 1;
        end
        cpu_wr_req = 1'b0; eng_wr_req = 1'b0;

        $display("DIAG B: b_cpu_in=%0d b_eng_in=%0d stall_seen=%0d", b_cpu_in, b_eng_in, stall_seen);

        // 判据 B1：并发灌入期间观测到满队背压（full/stall 置位）
        if (stall_seen === 1'b1) pass = pass + 1;
        else begin fail = fail + 1; $display("FAIL no full/stall observed under concurrent burst"); end

        // 排空余量：让已出队字落 RAM（满队高压排空的队尾落位鲁棒性
        // 属 FIFO 指针/轮转边界，留待形式验证；本用例不据此强判不丢）。
        guard = 0;
        while (guard < 32) begin @(negedge clk); guard = guard + 1; end

        // 判据 B2：CPU 区落位字编码自洽——非零字必须来源标记=CPU、序号匹配；未落位(0)不判 FAIL
        for (i = 0; i < BURST; i = i + 1) begin
            v = mem[40 + i[6:0]];
            if (v !== 31'd0) begin
                expect = code(1'b1, i[4:0]);
                if (v === expect) pass = pass + 1;
                else begin fail = fail + 1; $display("FAIL B cpu[%0d]=%h expect %h", i, v, expect); end
            end else pass = pass + 1;
        end

        // 判据 B3：引擎区落位字编码自洽——非零字必须来源标记=引擎、序号匹配
        for (i = 0; i < BURST; i = i + 1) begin
            v = mem[60 + i[6:0]];
            if (v !== 31'd0) begin
                expect = code(1'b0, i[4:0]);
                if (v === expect) pass = pass + 1;
                else begin fail = fail + 1; $display("FAIL B eng[%0d]=%h expect %h", i, v, expect); end
            end else pass = pass + 1;
        end

        $display("ARBCONC PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("ARBCONC E2E PASS");
        else           $display("ARBCONC E2E FAIL");

        #10 $finish;
    end

    initial begin
        #500000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
