// 探针 v4：1W1R 同步 + 一个组合直读口（模拟 ctrl/dbg 组合读旁路）
module probe_v4 #(
    parameter integer WORDS = 2048
)(
    input         clk,
    input         resetn,
    input         wr_en,
    input  [11:0] wr_addr,
    input  [30:0] wr_data,
    input         rd_en,
    input  [11:0] rd_addr,
    output [30:0] rd_data,
    input  [11:0] combo_addr,
    output [30:0] combo_data
);
    reg [30:0] mem [0:WORDS-1];
    reg [30:0] rd_data_r;

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end

    always @(posedge clk) begin
        if (~resetn) rd_data_r <= 31'b0;
        else if (rd_en) rd_data_r <= mem[rd_addr];
    end

    assign rd_data = rd_data_r;
    assign combo_data = mem[combo_addr];
endmodule
