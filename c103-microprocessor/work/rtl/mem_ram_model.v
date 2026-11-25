/**
 * 103 复刻 · 行为单口 RAM 模型（独立 iverilog 闭环用）
 *
 * 对齐既有 memory 对外口径：31 位字（{sign, 30 数值位}），12 位地址。
 * 本模型用于 work/ 下独立 iverilog 通路闭环，不替代既有 verify/hardware 仓库
 * 内的 S011 / Gowin_SP 存储实例。
 *
 * 时序口径（对齐真实 BRAM 同步读）：
 *  - 同步写：wr_en 拍把 wr_data 写入 wr_addr；
 *  - 同步读：rd_addr 拍给地址，rd_data 经一级 read_data_r 在下一拍有效
 *    （与 Gowin/ASIC 块 RAM 的一拍读延迟一致）；消费侧 FSM 需在取数前
 *    预留一个等待拍，不能当拍锁存 rd_data。
 *  - dbg_* 为仿真调试口：testbench 直接预填镜像 / 直读校验，保持组合读，
 *    不参与功能通路，综合上板时整口可移除。
 */

module mem_ram_model #(
    parameter integer WORDS = 4096
)(
    input         clk,
    input         resetn,

    // 功能写口（接仲裁器输出）
    input         wr_en,
    input  [11:0] wr_addr,
    input  [30:0] wr_data,

    // 功能读口（同步读，一拍延迟）
    input  [11:0] rd_addr,
    output [30:0] rd_data,

    // 调试写口（testbench 预填镜像）
    input         dbg_wr_en,
    input  [11:0] dbg_wr_addr,
    input  [30:0] dbg_wr_data,

    // 调试读口（testbench 校验直读，组合）
    input  [11:0] dbg_rd_addr,
    output [30:0] dbg_rd_data
);

    reg [30:0] mem [0:WORDS-1];
    reg [30:0] rd_data_r;

    always @(posedge clk) begin
        if (wr_en)       mem[wr_addr]    <= wr_data;
        if (dbg_wr_en)   mem[dbg_wr_addr] <= dbg_wr_data;
    end

    // 同步读：每拍锁存当前地址字，下一拍输出（BRAM 口径）
    always @(posedge clk) begin
        rd_data_r <= mem[rd_addr];
    end

    assign rd_data    = rd_data_r;
    assign dbg_rd_data = mem[dbg_rd_addr];

endmodule
