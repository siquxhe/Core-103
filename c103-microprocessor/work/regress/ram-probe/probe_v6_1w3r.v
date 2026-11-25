// 探针 v6：1W3R，三个时序读口（检验第三读口是否超双口 BRAM 容量）
module probe_v6 #(
    parameter integer WORDS = 2048
)(
    input         clk,
    input         resetn,
    input         wr_en,
    input  [11:0] wr_addr,
    input  [30:0] wr_data,
    input         rd1_en,
    input  [11:0] rd1_addr,
    output [30:0] rd1_data,
    input         rd2_en,
    input  [11:0] rd2_addr,
    output [30:0] rd2_data,
    input         rd3_en,
    input  [11:0] rd3_addr,
    output [30:0] rd3_data
);
    reg [30:0] mem [0:WORDS-1];
    reg [30:0] rd1_data_r, rd2_data_r, rd3_data_r;

    always @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
    end
    always @(posedge clk) begin
        if (~resetn) rd1_data_r <= 31'b0;
        else if (rd1_en) rd1_data_r <= mem[rd1_addr];
    end
    always @(posedge clk) begin
        if (~resetn) rd2_data_r <= 31'b0;
        else if (rd2_en) rd2_data_r <= mem[rd2_addr];
    end
    always @(posedge clk) begin
        if (~resetn) rd3_data_r <= 31'b0;
        else if (rd3_en) rd3_data_r <= mem[rd3_addr];
    end

    assign rd1_data = rd1_data_r;
    assign rd2_data = rd2_data_r;
    assign rd3_data = rd3_data_r;
endmodule
