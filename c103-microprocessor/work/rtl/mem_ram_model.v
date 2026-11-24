/**
 * 103 复刻 · 行为单口 RAM 模型（独立 iverilog 闭环用）
 *
 * 对齐既有 memory 对外口径：31 位字（{sign, 30 数值位}），12 位地址。
 * 本模型用于 work/ 下独立 iverilog 通路闭环，不替代既有 verify/hardware 仓库
 * 内的 S011 / Gowin_SP 存储实例。
 *
 * 时序假设（第一步通路自检）：
 *  - 同步写：wr_en 拍把 wr_data 写入 wr_addr；
 *  - 组合读：rd_data 当拍随 rd_addr 有效。既有 memory.v 为同步读 + 一级
 *    read_data_r 缓冲；第二步接核心时，按核心 FSM 适配的读延迟在此模型或
 *    通路层补读缓冲，不改引擎 FSM 节拍。
 *  - dbg_* 为仿真调试口：testbench 直接预填镜像 / 直读校验，不参与功能通路。
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

    // 功能读口（组合读）
    input  [11:0] rd_addr,
    output [30:0] rd_data,

    // 调试写口（testbench 预填镜像）
    input         dbg_wr_en,
    input  [11:0] dbg_wr_addr,
    input  [30:0] dbg_wr_data,

    // 调试读口（testbench 校验直读）
    input  [11:0] dbg_rd_addr,
    output [30:0] dbg_rd_data
);

    reg [30:0] mem [0:WORDS-1];

    always @(posedge clk) begin
        if (wr_en)       mem[wr_addr]    <= wr_data;
        if (dbg_wr_en)   mem[dbg_wr_addr] <= dbg_wr_data;
    end

    assign rd_data    = mem[rd_addr];
    assign dbg_rd_data = mem[dbg_rd_addr];

endmodule
