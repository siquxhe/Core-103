/**
 * 装配模块闭环 testbench · engine_ctrl ↔ copy_engine ↔ 共享 RAM 命令块
 *
 * 阶段 A（桥模型层）：命令参数由调试口写入命令块；engine_ctrl 取参、锁存
 * 引擎寄存器并发 go；引擎搬运；ctrl 把 busy/done/err 回写命令块状态镜像；
 * 桥模型轮询 DONE 镜像后写 ACK，ctrl 握手清状态、引擎回 IDLE。
 *
 * 命令块（八进制）：
 *   2400 SRC / 2401 DST / 2402 LEN / 2403 GO /
 *   2404 BUSY / 2405 DONE / 2406 ERR / 2407 ACK
 *
 * 用例：源区 1500 起 3 字（3,4,5）→ 目的区 3000 起；校验落位与状态镜像。
 */

`timescale 1ns/1ps

module tb_engine_ctrl;

    // ---- 时钟 / 复位 ----
    reg clk;
    reg resetn;

    // ---- dev 握手（本用例不启用 IO，保持默认） ----
    wire        dev_input_rdy;
    reg         dev_input_val;
    wire        dev_output_rdy;
    reg         dev_output_ack;
    reg  [4:0]  dev_input_data;
    wire [4:0]  dev_output_data;

    // ---- 面板 ----
    reg         pnl_start_pulse, pnl_clear_pu, pnl_automatic;
    reg         pnl_mem_read, pnl_mem_write;
    reg         pnl_start_input, pnl_stop_input;
    reg         pnl_start_output, pnl_stop_output;
    reg         pnl_input_dec, pnl_output_dec;
    reg         pnl_continuous_input, pnl_stop_after_output;
    reg         pnl_stop_at_cmp, pnl_cmp_with_strt;
    reg         pnl_do_arr_c;
    reg  [30:0] pnl_arr_reg_c_value;
    reg         pnl_do_arr_strt;
    reg  [11:0] pnl_arr_strt_value;
    reg         pnl_do_arr_sel;
    reg  [11:0] pnl_arr_sel_value;
    reg  [11:0] pnl_arr_cmp_value;
    wire        pnl_input_active, pnl_output_active;
    wire [5:0]  pnl_op_code;
    wire [11:0] pnl_strt_value, pnl_sel_value;
    wire [30:0] pnl_reg_c_value;
    wire [2:0]  pnl_pu_state;

    // ---- 引擎旁路 ----
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;

    // ---- 命令块旁路（ctrl） ----
    wire        ctrl_rd_req;
    wire [11:0] ctrl_rd_addr;
    wire [30:0] ctrl_rd_data;
    wire        ctrl_wr_req;
    wire [11:0] ctrl_wr_addr;
    wire [30:0] ctrl_wr_data;

    // ---- 调试口 ----
    reg         dbg_wr_en;
    reg  [11:0] dbg_wr_addr, dbg_rd_addr;
    reg  [30:0] dbg_wr_data;
    wire [30:0] dbg_rd_data;

    // ---- ctrl ↔ 引擎 命令 / 状态 ----
    wire [11:0] cmd_src, cmd_dst, cmd_len;
    wire        cmd_go, ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  eng_state;
    wire [11:0] remain;

    // ---- 命令块地址（八进制） ----
    localparam [11:0] A_SRC  = 12'o2400;
    localparam [11:0] A_DST  = 12'o2401;
    localparam [11:0] A_LEN   = 12'o2402;
    localparam [11:0] A_GO    = 12'o2403;
    localparam [11:0] A_BUSY  = 12'o2404;
    localparam [11:0] A_DONE  = 12'o2405;
    localparam [11:0] A_ERR   = 12'o2406;
    localparam [11:0] A_ACK   = 12'o2407;

    // 纸带 5-bit 符号编码（对齐 tape.h / io_unit 译码）
    localparam [4:0] TAPE_SEL  = 5'h01;  // @  置地址
    localparam [4:0] TAPE_POS  = 5'h1E;  // +  正号
    localparam [4:0] TAPE_WRITE= 5'h06;  // 换行 写内存
    localparam [4:0] TAPE_NUM0 = 5'h10;

    localparam [11:0] MEM_SRC = 12'o1500;
    localparam [11:0] MEM_DST = 12'o3000;
    localparam [11:0] MLEN    = 12'd3;

    integer pass, fail;
    reg [30:0] r0, r1, r2;
    reg saw_busy;
    integer guard;

    initial clk = 1'b0;
    always #1 clk = ~clk;

    // ---- DUT：核心（含共享 RAM） ----
    core_top u_core (
        .clk                     ( clk                     ),
        .resetn                  ( resetn                  ),
        .dev_input_rdy           ( dev_input_rdy           ),
        .dev_input_val           ( dev_input_val           ),
        .dev_output_rdy          ( dev_output_rdy          ),
        .dev_output_ack          ( dev_output_ack         ),
        .dev_input_data          ( dev_input_data          ),
        .dev_output_data         ( dev_output_data         ),
        .pnl_start_pulse         ( pnl_start_pulse         ),
        .pnl_clear_pu            ( pnl_clear_pu            ),
        .pnl_automatic           ( pnl_automatic           ),
        .pnl_mem_read            ( pnl_mem_read            ),
        .pnl_mem_write           ( pnl_mem_write           ),
        .pnl_start_input         ( pnl_start_input         ),
        .pnl_stop_input          ( pnl_stop_input          ),
        .pnl_start_output       ( pnl_start_output        ),
        .pnl_stop_output         ( pnl_stop_output         ),
        .pnl_input_dec           ( pnl_input_dec           ),
        .pnl_output_dec          ( pnl_output_dec         ),
        .pnl_continuous_input    ( pnl_continuous_input    ),
        .pnl_stop_after_output   ( pnl_stop_after_output   ),
        .pnl_stop_at_cmp         ( pnl_stop_at_cmp         ),
        .pnl_cmp_with_strt       ( pnl_cmp_with_strt       ),
        .pnl_do_arr_c            ( pnl_do_arr_c            ),
        .pnl_arr_reg_c_value     ( pnl_arr_reg_c_value     ),
        .pnl_do_arr_strt         ( pnl_do_arr_strt         ),
        .pnl_arr_strt_value      ( pnl_arr_strt_value     ),
        .pnl_do_arr_sel          ( pnl_do_arr_sel           ),
        .pnl_arr_sel_value       ( pnl_arr_sel_value       ),
        .pnl_arr_cmp_value       ( pnl_arr_cmp_value       ),
        .pnl_input_active        ( pnl_input_active        ),
        .pnl_output_active       ( pnl_output_active        ),
        .pnl_op_code             ( pnl_op_code             ),
        .pnl_strt_value          ( pnl_strt_value          ),
        .pnl_sel_value           ( pnl_sel_value           ),
        .pnl_reg_c_value         ( pnl_reg_c_value         ),
        .pnl_pu_state            ( pnl_pu_state            ),
        .eng_rd_req              ( eng_rd_req              ),
        .eng_rd_addr             ( eng_rd_addr             ),
        .eng_rd_data             ( eng_rd_data            ),
        .eng_wr_req              ( eng_wr_req              ),
        .eng_wr_addr             ( eng_wr_addr             ),
        .eng_wr_data             ( eng_wr_data             ),
        .ctrl_rd_req             ( ctrl_rd_req            ),
        .ctrl_rd_addr            ( ctrl_rd_addr           ),
        .ctrl_rd_data            ( ctrl_rd_data           ),
        .ctrl_wr_req             ( ctrl_wr_req            ),
        .ctrl_wr_addr            ( ctrl_wr_addr           ),
        .ctrl_wr_data            ( ctrl_wr_data           ),
        .dbg_wr_en               ( dbg_wr_en               ),
        .dbg_wr_addr             ( dbg_wr_addr             ),
        .dbg_wr_data             ( dbg_wr_data            ),
        .dbg_rd_addr             ( dbg_rd_addr            ),
        .dbg_rd_data             ( dbg_rd_data            )
    );

    // ---- DUT：引擎 ----
    copy_engine #(.MEM_SIZE(2048)) u_eng (
        .clk            ( clk         ),
        .resetn         ( resetn       ),
        .cmd_src        ( cmd_src      ),
        .cmd_dst        ( cmd_dst      ),
        .cmd_len        ( cmd_len      ),
        .cmd_go         ( cmd_go       ),
        .rd_addr        ( eng_rd_addr  ),
        .rd_req         ( eng_rd_req   ),
        .rd_data        ( eng_rd_data  ),
        .wr_addr        ( eng_wr_addr  ),
        .wr_data        ( eng_wr_data  ),
        .wr_req         ( eng_wr_req   ),
        .ack_done       ( ack_done     ),
        .ack_err        ( ack_err       ),
        .busy           ( busy         ),
        .done           ( done         ),
        .err            ( err           ),
        .err_code       ( err_code     ),
        .state          ( eng_state    ),
        .remain         ( remain       )
    );

    // ---- DUT：装配模块 ----
    engine_ctrl #(
        .ADDR_SRC(A_SRC), .ADDR_DST(A_DST), .ADDR_LEN(A_LEN), .ADDR_GO(A_GO),
        .ADDR_BUSY(A_BUSY), .ADDR_DONE(A_DONE), .ADDR_ERR(A_ERR), .ADDR_ACK(A_ACK)
    ) u_ctrl (
        .clk            ( clk         ),
        .resetn         ( resetn       ),
        .ctrl_rd_req    ( ctrl_rd_req  ),
        .ctrl_rd_addr   ( ctrl_rd_addr ),
        .ctrl_rd_data   ( ctrl_rd_data ),
        .ctrl_wr_req    ( ctrl_wr_req  ),
        .ctrl_wr_addr   ( ctrl_wr_addr),
        .ctrl_wr_data   ( ctrl_wr_data ),
        .cmd_src        ( cmd_src      ),
        .cmd_dst        ( cmd_dst      ),
        .cmd_len        ( cmd_len      ),
        .cmd_go         ( cmd_go       ),
        .ack_done       ( ack_done     ),
        .ack_err        ( ack_err       ),
        .busy           ( busy         ),
        .done           ( done          ),
        .err            ( err           ),
        .err_code       ( err_code     )
    );

    // ---- 调试写 ----
    task dbg_fill;
        input [11:0] addr;
        input [30:0] data;
        begin
            @(negedge clk);
            dbg_wr_en   = 1'b1;
            dbg_wr_addr = addr;
            dbg_wr_data = data;
            @(negedge clk);
            dbg_wr_en = 1'b0;
        end
    endtask

    // ---- 调试读 ----
    task dbg_read;
        input  [11:0] addr;
        output [30:0] data;
        begin
            @(negedge clk);
            dbg_rd_addr = addr;
            @(negedge clk);
            @(negedge clk);
            data = dbg_rd_data;
        end
    endtask

    // ---- 纸带符号编码：八进制数字 0..7 ----
    function [4:0] tape_num;
        input [3:0] d;
        begin
            tape_num = TAPE_NUM0 + {1'b0, d[2:0]};
        end
    endfunction

    // ---- 发一个 5-bit 符号（对齐 io_unit 输入握手） ----
    task send_sym;
        input [4:0] sym;
        begin
            wait (dev_input_rdy);
            @(negedge clk);
            dev_input_val  = 1'b1;
            dev_input_data = sym;
            wait (!dev_input_rdy);
            @(negedge clk);
            dev_input_val = 1'b0;
        end
    endtask

    // ---- 经纸带流写一个命令字：地址数字 → sel → 正号 → 值数字 → write ----
    task tape_write;
        input [3:0] a3, a2, a1, a0;   // 地址四位八进制
        input [3:0] v3, v2, v1, v0;   // 值四位八进制（高位为 0 时发 0）
        begin
            send_sym(tape_num(a3));
            send_sym(tape_num(a2));
            send_sym(tape_num(a1));
            send_sym(tape_num(a0));
            send_sym(TAPE_SEL);
            send_sym(TAPE_POS);
            send_sym(tape_num(v3));
            send_sym(tape_num(v2));
            send_sym(tape_num(v1));
            send_sym(tape_num(v0));
            send_sym(TAPE_WRITE);
        end
    endtask

    reg [30:0] tmp;

    // ---- 主流程 ----
    initial begin
        resetn = 1'b0;
        dev_input_val = 1'b0; dev_output_ack = 1'b0; dev_input_data = 5'd0;
        pnl_start_pulse = 0; pnl_clear_pu = 0; pnl_automatic = 1;
        pnl_mem_read = 0; pnl_mem_write = 0;
        pnl_start_input = 0; pnl_stop_input = 0;
        pnl_start_output = 0; pnl_stop_output = 0;
        pnl_input_dec = 0; pnl_output_dec = 0;
        pnl_continuous_input = 0; pnl_stop_after_output = 0;
        pnl_stop_at_cmp = 0; pnl_cmp_with_strt = 0;
        pnl_do_arr_c = 0; pnl_arr_reg_c_value = 0;
        pnl_do_arr_strt = 0; pnl_arr_strt_value = 0;
        pnl_do_arr_sel = 0; pnl_arr_sel_value = 0;
        pnl_arr_cmp_value = 0;
        dbg_wr_en = 0; dbg_wr_addr = 0; dbg_wr_data = 0; dbg_rd_addr = 0;
        pass = 0; fail = 0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // 装载期：连续输入、八进制、automatic=0（io+ac 移位链自走）
        pnl_continuous_input = 1'b1;
        pnl_input_dec = 1'b0;
        pnl_automatic = 1'b0;

        // 0) 预清命令块状态字，避免 RAM 初值 x 干扰全等比较
        dbg_fill(A_BUSY, 31'd0);
        dbg_fill(A_DONE, 31'd0);
        dbg_fill(A_ERR,  31'd0);
        dbg_fill(A_ACK,  31'd0);

        // 1) 预填源区数据 3,4,5（调试口，不经命令流）
        dbg_fill(MEM_SRC + 12'd0, 31'd3);
        dbg_fill(MEM_SRC + 12'd1, 31'd4);
        dbg_fill(MEM_SRC + 12'd2, 31'd5);

        // 2) 激活输入，经 5-bit 纸带符号流写命令块参数（先不写 GO）
        @(negedge clk);
        pnl_start_input = 1'b1;
        #4;
        pnl_start_input = 1'b0;

        // 2400 ← 1500（源地址）
        tape_write(4'd2,4'd4,4'd0,4'd0,  4'd1,4'd5,4'd0,4'd0);
        // 2401 ← 3000（目的地址）
        tape_write(4'd2,4'd4,4'd0,4'd1,  4'd3,4'd0,4'd0,4'd0);
        // 2402 ← 0003（长度）
        tape_write(4'd2,4'd4,4'd0,4'd2,  4'd0,4'd0,4'd0,4'd3);

        // 2b) 读回命令块参数（ctrl 尚未启动），校验纸带流落位
        dbg_read(A_SRC, tmp);
        if (tmp[11:0] === MEM_SRC) pass = pass + 1; else begin fail = fail + 1; $display("FAIL SRC=%h expect %o", tmp, MEM_SRC); end
        dbg_read(A_DST, tmp);
        if (tmp[11:0] === MEM_DST) pass = pass + 1; else begin fail = fail + 1; $display("FAIL DST=%h expect %o", tmp, MEM_DST); end
        dbg_read(A_LEN, tmp);
        if (tmp[11:0] === MLEN)    pass = pass + 1; else begin fail = fail + 1; $display("FAIL LEN=%h expect %o", tmp, MLEN); end

        // 2c) 单独写 GO=1；ctrl 采样后自清 GO，故不再读回 GO==1
        tape_write(4'd2,4'd4,4'd0,4'd3,  4'd0,4'd0,4'd0,4'd1);

        @(negedge clk);
        pnl_stop_input = 1'b1;
        #4;
        pnl_stop_input = 1'b0;

        // 3) 桥模型轮询：等待 DONE 镜像；期间观测 BUSY
        guard = 0;
        saw_busy = 1'b0;
        dbg_read(A_DONE, tmp);
        while (tmp !== 31'd1 && guard < 100000) begin
            @(negedge clk);
            guard = guard + 1;
            dbg_read(A_BUSY, tmp);
            if (tmp === 31'd1) saw_busy = 1'b1;
            dbg_read(A_DONE, tmp);
        end
        dbg_read(A_BUSY, tmp);
        r0 = tmp;
        dbg_read(A_DONE, tmp);
        $display("after wait: DONE=%0d BUSY=%0d saw_busy=%0d guard=%0d", tmp, r0, saw_busy, guard);
        if (tmp === 31'd1) pass = pass + 1; else begin fail = fail + 1; $display("FAIL DONE mirror"); end
        // BUSY 窗口短（3 字搬运），saw_busy 仅作观测，不作失败判据
        $display("INFO saw_busy=%0d", saw_busy);

        dbg_read(A_ERR, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL ERR mirror=%h", tmp); end

        // 4) 校验目的区落位
        dbg_read(MEM_DST + 12'd0, r0);
        dbg_read(MEM_DST + 12'd1, r1);
        dbg_read(MEM_DST + 12'd2, r2);
        $display("dst: %0d %0d %0d expect 3 4 5", r0, r1, r2);
        if (r0 === 31'd3) pass = pass + 1; else fail = fail + 1;
        if (r1 === 31'd4) pass = pass + 1; else fail = fail + 1;
        if (r2 === 31'd5) pass = pass + 1; else fail = fail + 1;

        // 5) 写 ACK，等 ctrl 自清并回 IDLE
        dbg_fill(A_ACK, 31'd1);
        guard = 0;
        dbg_read(A_ACK, tmp);
        while (tmp !== 31'd0 && guard < 100000) begin
            @(negedge clk);
            guard = guard + 1;
            dbg_read(A_ACK, tmp);
        end
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL ACK not cleared"); end
        if (eng_state === 3'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL engine not IDLE state=%0d", eng_state); end

        // 握手收尾：DONE / ERR 镜像必须随 ack 一并清零，不得残留到下一轮
        dbg_read(A_DONE, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL DONE mirror residual=%h", tmp); end
        dbg_read(A_ERR, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL ERR mirror residual=%h", tmp); end

        $display("ENG-CTRL PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("ENG-CTRL E2E PASS");
        else           $display("ENG-CTRL E2E FAIL");

        #10 $finish;
    end

    initial begin
        #200000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
