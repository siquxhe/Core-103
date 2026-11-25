// 探针 v1：1W1R 同步读，标准单口 BRAM 推断基线
module probe_v1 #(
    parameter integer WORDS = 2048
)(
    input         clk,
    input         resetn,
    input         wr_en,
    input  [11:0] wr_addr,
    input  [30:0] wr_data,
    input         rd_en,
    input  [11:0] rd_addr,
    output [30:0] rd_data
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
endmodule
