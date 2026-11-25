// 探针 v5：2W1R，双写分到两个独立 always 块（检验写法 vs 双写语义）
module probe_v5 #(
    parameter integer WORDS = 2048
)(
    input         clk,
    input         resetn,
    input         wr1_en,
    input  [11:0] wr1_addr,
    input  [30:0] wr1_data,
    input         wr2_en,
    input  [11:0] wr2_addr,
    input  [30:0] wr2_data,
    input         rd_en,
    input  [11:0] rd_addr,
    output [30:0] rd_data
);
    reg [30:0] mem [0:WORDS-1];
    reg [30:0] rd_data_r;

    always @(posedge clk) begin
        if (wr1_en) mem[wr1_addr] <= wr1_data;
    end

    always @(posedge clk) begin
        if (wr2_en) mem[wr2_addr] <= wr2_data;
    end

    always @(posedge clk) begin
        if (~resetn) rd_data_r <= 31'b0;
        else if (rd_en) rd_data_r <= mem[rd_addr];
    end

    assign rd_data = rd_data_r;
endmodule
