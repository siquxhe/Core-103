/**
 * 仲裁器形式验证包装层 · mem_write_arbiter（#87）
 *
 * 不改动自研 RTL；本 wrapper 例化仲裁器，在 FORMAL 段声明待证不变量。
 * 只使用外部可见端口信号（跨层次读内部 wp/rp 会被 yosys 判为无驱动 wire，
 * 故队列不溢出/不丢守恒不在此跨层次断言；守恒由仿真 enq==deq==wr 用例覆盖）。
 *
 * 待证不变量：
 *   1. 授权互斥：grant_cpu 与 grant_eng 永不同拍（RAM 单写口不双写）。
 * cover：满队标志可达（背压路径真实存在）；双授权不可达（反向校验互斥）。
 */

`timescale 1ns/1ps

module arb_formal;

    localparam integer DEPTH = 4;

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
    wire        grant_cpu, grant_eng, conflict;
    wire        cpu_full, eng_full, cpu_stall, eng_stall;

    mem_write_arbiter #(.FIFO_DEPTH(DEPTH)) dut (
        .clk(clk), .resetn(resetn),
        .cpu_wr_req(cpu_wr_req), .cpu_wr_addr(cpu_wr_addr), .cpu_wr_data(cpu_wr_data),
        .eng_wr_req(eng_wr_req), .eng_wr_addr(eng_wr_addr), .eng_wr_data(eng_wr_data),
        .ram_wr_req(ram_wr_req), .ram_wr_addr(ram_wr_addr), .ram_wr_data(ram_wr_data),
        .grant_cpu(grant_cpu), .grant_eng(grant_eng), .conflict(conflict),
        .cpu_full(cpu_full), .eng_full(eng_full),
        .cpu_stall(cpu_stall), .eng_stall(eng_stall)
    );

`ifdef FORMAL
    always @(posedge clk) begin
        if (resetn) begin
            // 不变量 1：授权互斥，无双授权（RAM 单写口不双写）
            assert property (!(grant_cpu && grant_eng));
        end
    end

    // 满队标志可达（背压路径真实存在）
    cover property (cpu_full);
    cover property (eng_full);
    // 反向校验：双授权不应可达；若该 cover 被满足，互斥失效
    cover property (grant_cpu && grant_eng);
`endif

endmodule
