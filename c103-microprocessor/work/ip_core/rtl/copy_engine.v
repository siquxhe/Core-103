/**
 * 103 复刻 · 硬件拷贝引擎（RTL）
 *
 * 与行为级 C 原型 ../../engine/copy_engine.c 一一对应：
 *   状态机 IDLE -> ARM -> FETCH -> WRITE -> CHECK -> DONE / ERR
 *
 * 时序惯例与既有 RTL 一致：clk 上升沿，resetn 低有效复位。
 * 字宽 31 位（{sign, 30 数值位}），地址 12 位。
 *
 * 内存接口约定（本阶段）：
 *  - 读口为同步 RAM 模型的组合读：FETCH 态给出 rd_addr/rd_req，当拍 rd_data 有效；
 *    真实 Gowin/ASIC RAM 有一拍读延迟，挂接时在引擎与 RAM 之间补一级读缓冲
 *    （参照 memory_fpga.v 的 read_data_r 做法），不改本 FSM 节拍。
 *  - 写口经 mem_write_arbiter 接到共享 RAM；仲裁队列满时 wr_stall 置位，
 *    WRITE 态停留重试，不推进指针、不丢当前字。
 */

module copy_engine #(
    parameter integer MEM_SIZE = 4096
)(
    input         clk,
    input         resetn,

    // ---- 命令寄存器（核心写，go 之前电平保持） ----
    input  [11:0] cmd_src,
    input  [11:0] cmd_dst,
    input  [11:0] cmd_len,
    input         cmd_go,          // 启动脉冲，IDLE 态采样

    // ---- 共享 RAM 读口 ----
    output [11:0] rd_addr,
    output        rd_req,
    input  [30:0] rd_data,

    // ---- 共享 RAM 写口（接仲裁器） ----
    output [11:0] wr_addr,
    output [30:0] wr_data,
    output        wr_req,
    input         wr_stall,       // 仲裁器背压：1 = 写队列满，本拍停留重试

    // ---- 完成 / 错误握手 ----
    input         ack_done,
    input         ack_err,

    // ---- 状态输出 ----
    output        busy,
    output        done,
    output        err,
    output [1:0]  err_code,
    output [2:0]  state,
    output [11:0] remain
);

// FSM 状态编码（对齐 copy_engine_t 枚举）
localparam [2:0] ST_IDLE  = 3'd0;
localparam [2:0] ST_ARM   = 3'd1;
localparam [2:0] ST_FETCH = 3'd2;
localparam [2:0] ST_WRITE = 3'd3;
localparam [2:0] ST_CHECK = 3'd4;
localparam [2:0] ST_DONE  = 3'd5;
localparam [2:0] ST_ERR   = 3'd6;

// 错误码（对齐 C 原型）
localparam [1:0] ERR_NONE     = 2'd0;
localparam [1:0] ERR_SRC_OOB  = 2'd1;
localparam [1:0] ERR_DST_OOB  = 2'd2;
localparam [1:0] ERR_ZERO_LEN = 2'd3;

// ---- 内部寄存器 ----
reg [2:0]  state_r;
reg [11:0] src_r;
reg [11:0] dst_r;
reg [11:0] len_r;
reg [11:0] src_ptr_r;
reg [11:0] dst_ptr_r;
reg [11:0] remain_r;
reg [30:0] latch_word_r;

reg        busy_r;
reg        done_r;
reg        err_r;
reg [1:0]  err_code_r;

// ---- 边界检查（组合） ----
wire len_zero = (len_r == 12'd0);

// 13 位加法避免 src+len-1 在 12 位内回绕
wire [12:0] src_last = {1'b0, src_r} + {1'b0, len_r} - 13'd1;
wire [12:0] dst_last = {1'b0, dst_r} + {1'b0, len_r} - 13'd1;

wire src_oob = (src_r >= MEM_SIZE) || (src_last >= MEM_SIZE);
wire dst_oob = (dst_r >= MEM_SIZE) || (dst_last >= MEM_SIZE);

// 背压输入归一化：未接端口为 z/x 时视为未背压（0）
wire wr_stall_i = (wr_stall === 1'b1);

// ---- 内存口驱动 ----
assign rd_addr = src_ptr_r;
assign rd_req  = (state_r == ST_FETCH);

assign wr_addr = dst_ptr_r;
assign wr_data = latch_word_r;
assign wr_req  = (state_r == ST_WRITE);

// ---- 状态输出 ----
assign state   = state_r;
assign busy    = busy_r;
assign done    = done_r;
assign err     = err_r;
assign err_code = err_code_r;
assign remain  = remain_r;

// ---- FSM ----
always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state_r     <= ST_IDLE;
        src_r       <= 12'd0;
        dst_r       <= 12'd0;
        len_r       <= 12'd0;
        src_ptr_r   <= 12'd0;
        dst_ptr_r   <= 12'd0;
        remain_r    <= 12'd0;
        latch_word_r<= 31'd0;
        busy_r      <= 1'b0;
        done_r      <= 1'b0;
        err_r       <= 1'b0;
        err_code_r  <= ERR_NONE;
    end else begin
        case (state_r)
        ST_IDLE: begin
            if (cmd_go) begin
                src_r  <= cmd_src;
                dst_r  <= cmd_dst;
                len_r  <= cmd_len;
                busy_r <= 1'b1;
                state_r<= ST_ARM;
            end
        end

        ST_ARM: begin
            if (len_zero) begin
                err_code_r <= ERR_ZERO_LEN;
                err_r      <= 1'b1;
                busy_r     <= 1'b0;
                state_r    <= ST_ERR;
            end else if (src_oob) begin
                err_code_r <= ERR_SRC_OOB;
                err_r      <= 1'b1;
                busy_r     <= 1'b0;
                state_r    <= ST_ERR;
            end else if (dst_oob) begin
                err_code_r <= ERR_DST_OOB;
                err_r      <= 1'b1;
                busy_r     <= 1'b0;
                state_r    <= ST_ERR;
            end else begin
                src_ptr_r <= src_r;
                dst_ptr_r <= dst_r;
                remain_r  <= len_r;
                state_r   <= ST_FETCH;
            end
        end

        ST_FETCH: begin
            latch_word_r <= rd_data;
            state_r      <= ST_WRITE;
        end

        ST_WRITE: begin
            if (!wr_stall_i) begin
                src_ptr_r <= src_ptr_r + 12'd1;
                dst_ptr_r <= dst_ptr_r + 12'd1;
                remain_r  <= remain_r  - 12'd1;
                state_r   <= ST_CHECK;
            end
            // wr_stall_i=1：队列满，停留 WRITE 态；指针 / remain / 锁存字保持，
            // wr_req 随 state 保持为 1，待 stall 撤销后下一拍入队再推进 CHECK。
        end

        ST_CHECK: begin
            if (remain_r == 12'd0) begin
                busy_r  <= 1'b0;
                done_r  <= 1'b1;
                state_r <= ST_DONE;
            end else begin
                state_r <= ST_FETCH;
            end
        end

        ST_DONE: begin
            if (ack_done) begin
                done_r  <= 1'b0;
                state_r <= ST_IDLE;
            end
        end

        ST_ERR: begin
            if (ack_err) begin
                err_r      <= 1'b0;
                err_code_r <= ERR_NONE;
                state_r    <= ST_IDLE;
            end
        end

        default: begin
            state_r <= ST_IDLE;
        end
        endcase
    end
end

endmodule
