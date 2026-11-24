/**
 * 103 复刻 · 拷贝引擎装配 / 状态回写模块（engine_ctrl）
 *
 * 职责（不改内核译码与指令集，引擎作为外挂外设）：
 *  - 从共享 RAM 内固定命令块读取 src/dst/len 与 go 标志；
 *  - 锁存参数到 copy_engine 命令寄存器并发 cmd_go 脉冲；
 *  - 把引擎 busy/done/err/err_code 回写为命令块状态镜像，供核心程序
 *    （或桥模型）经普通内存读通路轮询；
 *  - 收到命令块 ack 字后向引擎发 ack_done / ack_err，引擎回 IDLE。
 *
 * 命令块布局（八进制地址，31 位字；低地址域放 12 位参数 / 标志）：
 *   2400 CMD_SRC   源地址
 *   2401 CMD_DST   目的地址
 *   2402 CMD_LEN   搬运字数
 *   2403 CMD_GO   非 0 启动；装配后自清
 *   2404 STS_BUSY  状态镜像：1=搬运中
 *   2405 STS_DONE   状态镜像：1=完成
 *   2406 STS_ERR    状态镜像：bit0=err，bit[2:1]=err_code
 *   2407 CMD_ACK   1=ack_done，2=ack_err；装配后自清
 *
 * 时序与既有 RTL 一致：clk 上升沿，resetn 低有效；命令块读为组合读，
 * 状态镜像写为同步写（与引擎旁路 eng_wr 同节奏）。
 */

module engine_ctrl #(
    parameter [11:0] ADDR_SRC  = 12'o2400,
    parameter [11:0] ADDR_DST  = 12'o2401,
    parameter [11:0] ADDR_LEN   = 12'o2402,
    parameter [11:0] ADDR_GO    = 12'o2403,
    parameter [11:0] ADDR_BUSY  = 12'o2404,
    parameter [11:0] ADDR_DONE  = 12'o2405,
    parameter [11:0] ADDR_ERR   = 12'o2406,
    parameter [11:0] ADDR_ACK   = 12'o2407
)(
    input         clk,
    input         resetn,

    // ---- 命令块内存旁路 ----
    output        ctrl_rd_req,
    output [11:0] ctrl_rd_addr,
    input  [30:0] ctrl_rd_data,
    output        ctrl_wr_req,
    output [11:0] ctrl_wr_addr,
    output [30:0] ctrl_wr_data,

    // ---- 到拷贝引擎 ----
    output [11:0] cmd_src,
    output [11:0] cmd_dst,
    output [11:0] cmd_len,
    output        cmd_go,
    output        ack_done,
    output        ack_err,

    // ---- 来自拷贝引擎 ----
    input         busy,
    input         done,
    input         err,
    input  [1:0]  err_code
);

// FSM 状态
localparam [2:0] S_IDLE    = 3'd0;
localparam [2:0] S_LD_SRC  = 3'd1;
localparam [2:0] S_LD_DST  = 3'd2;
localparam [2:0] S_LD_LEN  = 3'd3;
localparam [2:0] S_ARMED    = 3'd4;
localparam [2:0] S_DONE     = 3'd5;
localparam [2:0] S_ERR      = 3'd6;

reg [2:0]  state_r;
reg [1:0]  phase_r;
reg [11:0] src_r, dst_r, len_r;
reg        go_pulse_r;
reg        ack_done_r, ack_err_r;

// 写口寄存器
reg        wr_req_r;
reg [11:0] wr_addr_r;
reg [30:0] wr_data_r;

// 读地址选择（组合）
reg [11:0] rd_addr_r;
assign ctrl_rd_req  = 1'b1;
assign ctrl_rd_addr = rd_addr_r;

// 命令寄存器输出
assign cmd_src  = src_r;
assign cmd_dst  = dst_r;
assign cmd_len  = len_r;
assign cmd_go   = go_pulse_r;
assign ack_done = ack_done_r;
assign ack_err  = ack_err_r;

// 写口输出
assign ctrl_wr_req  = wr_req_r;
assign ctrl_wr_addr = wr_addr_r;
assign ctrl_wr_data = wr_data_r;

wire [30:0] word_one  = 31'd1;
wire [30:0] word_zero  = 31'd0;

always @(posedge clk or negedge resetn) begin
    if (!resetn) begin
        state_r    <= S_IDLE;
        phase_r    <= 2'd0;
        src_r      <= 12'd0;
        dst_r      <= 12'd0;
        len_r      <= 12'd0;
        go_pulse_r <= 1'b0;
        ack_done_r <= 1'b0;
        ack_err_r  <= 1'b0;
        wr_req_r   <= 1'b0;
        wr_addr_r  <= 12'd0;
        wr_data_r  <= 31'd0;
        rd_addr_r  <= ADDR_GO;
    end else begin
        // 默认：写口撤请求，脉冲自清
        wr_req_r   <= 1'b0;
        go_pulse_r <= 1'b0;
        ack_done_r <= 1'b0;
        ack_err_r  <= 1'b0;

        case (state_r)

        S_IDLE: begin
            rd_addr_r <= ADDR_GO;
            phase_r   <= 2'd0;
            if (ctrl_rd_data != 31'd0) begin
                state_r   <= S_LD_SRC;
                rd_addr_r <= ADDR_SRC;
            end
        end

        S_LD_SRC: begin
            src_r     <= ctrl_rd_data[11:0];
            rd_addr_r <= ADDR_DST;
            state_r   <= S_LD_DST;
        end

        S_LD_DST: begin
            dst_r     <= ctrl_rd_data[11:0];
            rd_addr_r <= ADDR_LEN;
            state_r   <= S_LD_LEN;
        end

        S_LD_LEN: begin
            len_r      <= ctrl_rd_data[11:0];
            // 自清 go 标志，并发启动脉冲
            wr_req_r   <= 1'b1;
            wr_addr_r  <= ADDR_GO;
            wr_data_r  <= word_zero;
            go_pulse_r <= 1'b1;
            state_r    <= S_ARMED;
        end

        S_ARMED: begin
            // 回写 busy=1（幂等）
            wr_req_r  <= 1'b1;
            wr_addr_r <= ADDR_BUSY;
            wr_data_r <= word_one;
            phase_r   <= 2'd0;
            if (err) begin
                state_r <= S_ERR;
            end else if (done) begin
                state_r <= S_DONE;
            end
        end

        S_DONE: begin
            rd_addr_r <= ADDR_ACK;
            if (phase_r == 2'd0) begin
                // 首拍：清 busy
                wr_req_r  <= 1'b1;
                wr_addr_r <= ADDR_BUSY;
                wr_data_r <= word_zero;
                phase_r   <= 2'd1;
            end else if (phase_r == 2'd1) begin
                // 次拍：置 done 镜像
                wr_req_r  <= 1'b1;
                wr_addr_r <= ADDR_DONE;
                wr_data_r <= word_one;
                phase_r   <= 2'd2;
            end else if (phase_r == 2'd2) begin
                if (ctrl_rd_data != 31'd0) begin
                    // 收到 ack_done：发完成握手脉冲，清 ack 字
                    ack_done_r <= 1'b1;
                    wr_req_r   <= 1'b1;
                    wr_addr_r  <= ADDR_ACK;
                    wr_data_r  <= word_zero;
                    phase_r    <= 2'd3;
                end
            end else begin
                // 末拍：清 done 镜像，回 IDLE；命令块状态字全部回到干净态
                wr_req_r   <= 1'b1;
                wr_addr_r  <= ADDR_DONE;
                wr_data_r  <= word_zero;
                rd_addr_r  <= ADDR_GO;  // 回 IDLE 前切回 GO，避免首拍读到 ACK 残留误触发
                state_r    <= S_IDLE;
            end
        end

        S_ERR: begin
            rd_addr_r <= ADDR_ACK;
            if (phase_r == 2'd0) begin
                wr_req_r  <= 1'b1;
                wr_addr_r <= ADDR_BUSY;
                wr_data_r <= word_zero;
                phase_r   <= 2'd1;
            end else if (phase_r == 2'd1) begin
                wr_req_r  <= 1'b1;
                wr_addr_r <= ADDR_ERR;
                wr_data_r <= {28'd0, err_code, err};
                phase_r   <= 2'd2;
            end else if (phase_r == 2'd2) begin
                if (ctrl_rd_data != 31'd0) begin
                    ack_err_r <= 1'b1;
                    wr_req_r  <= 1'b1;
                    wr_addr_r <= ADDR_ACK;
                    wr_data_r <= word_zero;
                    phase_r   <= 2'd3;
                end
            end else begin
                // 末拍：清 err 镜像，回 IDLE
                wr_req_r  <= 1'b1;
                wr_addr_r <= ADDR_ERR;
                wr_data_r <= word_zero;
                rd_addr_r <= ADDR_GO;
                state_r   <= S_IDLE;
            end
        end

        default: state_r <= S_IDLE;
        endcase
    end
end

endmodule
