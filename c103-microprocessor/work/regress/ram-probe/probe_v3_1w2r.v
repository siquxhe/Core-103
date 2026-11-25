// 探针 v3：1W2R，两个时序读口（双口 RAM，B 口只读），模拟 CPU 读 + eng 读
module probe_v3 #(
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
    output [30:0] rd2_data
);
    reg [30:0] mem [0:WORDS-1];
    reg [30:0] rd1_data_r;
    reg [30:0] rd2_data_r;

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

    assign rd1_data = rd1_data_r;
    assign rd2_data = rd2_data_r;
endmodule
