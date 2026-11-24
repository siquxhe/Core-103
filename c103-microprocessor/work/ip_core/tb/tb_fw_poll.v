/**
 * 核心固件轮询 testbench · 核心程序读命令块状态、循环等待 done、写 ACK
 *
 * 流程：
 *  1. 纸带 5-bit 符号流写命令块 SRC/DST/LEN/GO；engine_ctrl 装配并搬运数据段；
 *  2. 桥模型轮询到 DONE=1（此阶段不写 ACK）；
 *  3. 调试口装入固件轮询子程序到程序区 0000，启动核心；
 *  4. 固件读 STS_DONE，减法判符号，条件跳转循环；完成后写 CMD_ACK；
 *  5. ctrl 收到 ACK 向引擎发 ack_done，引擎回 IDLE。
 *
 * 判据：数据段落位；DONE 镜像=1；核心停机；引擎回 IDLE（即固件已写 ACK 并完成握手）。
 *
 * 固件子程序（目的区，八进制地址）：
 *   2001 = 2^29（1/2 常量，作减法阈值）
 *   0000 +05 2405 2000  ; b = mem[DONE=2405]; mem[2000]=DONE
 *   0001 +01 2001 2000  ; c = b(2000) - a(2001=1/2)，存 2000
 *   0002 +05 2000 2002  ; b = c = 差值; mem[2002]=差值
 *   0003 +34 0000 0005  ; b 负(未完成)→0000 循环；非负(完成)→0005
 *   0005 +05 2001 2407  ; mem[ACK=2407]=1/2（非 0 即握手）
 *   0006 +54 0000 0000  ; 停机
 */

`timescale 1ns/1ps

module tb_fw_poll;

    reg clk;
    reg resetn;       // 引擎 / 装配模块全局复位（初始一次，之后保持）
    reg core_resetn;  // 核心 PU/IO 复位（启动核心前单独脉冲，不打断引擎握手）

    wire        dev_input_rdy;
    reg         dev_input_val;
    wire        dev_output_rdy;
    reg         dev_output_ack;
    reg  [4:0]  dev_input_data;
    wire [4:0]  dev_output_data;

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

    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;

    wire        ctrl_rd_req;
    wire [11:0] ctrl_rd_addr;
    wire [30:0] ctrl_rd_data;
    wire        ctrl_wr_req;
    wire [11:0] ctrl_wr_addr;
    wire [30:0] ctrl_wr_data;

    reg         dbg_wr_en;
    reg  [11:0] dbg_wr_addr, dbg_rd_addr;
    reg  [30:0] dbg_wr_data;
    wire [30:0] dbg_rd_data;

    wire [11:0] cmd_src, cmd_dst, cmd_len;
    wire        cmd_go, ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  eng_state;
    wire [11:0] remain;

    localparam [11:0] A_SRC  = 12'o2400;
    localparam [11:0] A_DST  = 12'o2401;
    localparam [11:0] A_LEN   = 12'o2402;
    localparam [11:0] A_GO    = 12'o2403;
    localparam [11:0] A_BUSY  = 12'o2404;
    localparam [11:0] A_DONE  = 12'o2405;
    localparam [11:0] A_ERR   = 12'o2406;
    localparam [11:0] A_ACK   = 12'o2407;

    localparam [11:0] MEM_SRC = 12'o1500;
    localparam [11:0] MEM_DST = 12'o3000;
    localparam [11:0] MLEN    = 12'd3;

    localparam [4:0] TAPE_SEL  = 5'h01;
    localparam [4:0] TAPE_POS  = 5'h1E;
    localparam [4:0] TAPE_WRITE= 5'h06;
    localparam [4:0] TAPE_NUM0 = 5'h10;

    integer pass, fail;
    reg [30:0] r0, r1, r2, tmp;
    integer guard;

    initial clk = 1'b0;
    always #1 clk = ~clk;

    function [30:0] inst;
        input [5:0]  op;
        input [11:0] c1;
        input [11:0] c2;
        begin
            inst = {1'b0, op, c1, c2};
        end
    endfunction

    function [30:0] dataw;
        input        sign;
        input [29:0] val;
        begin
            dataw = {sign, val};
        end
    endfunction

    core_top u_core (
        .clk(clk), .resetn(core_resetn),
        .dev_input_rdy(dev_input_rdy), .dev_input_val(dev_input_val),
        .dev_output_rdy(dev_output_rdy), .dev_output_ack(dev_output_ack),
        .dev_input_data(dev_input_data), .dev_output_data(dev_output_data),
        .pnl_start_pulse(pnl_start_pulse), .pnl_clear_pu(pnl_clear_pu),
        .pnl_automatic(pnl_automatic), .pnl_mem_read(pnl_mem_read),
        .pnl_mem_write(pnl_mem_write), .pnl_start_input(pnl_start_input),
        .pnl_stop_input(pnl_stop_input), .pnl_start_output(pnl_start_output),
        .pnl_stop_output(pnl_stop_output), .pnl_input_dec(pnl_input_dec),
        .pnl_output_dec(pnl_output_dec), .pnl_continuous_input(pnl_continuous_input),
        .pnl_stop_after_output(pnl_stop_after_output), .pnl_stop_at_cmp(pnl_stop_at_cmp),
        .pnl_cmp_with_strt(pnl_cmp_with_strt), .pnl_do_arr_c(pnl_do_arr_c),
        .pnl_arr_reg_c_value(pnl_arr_reg_c_value), .pnl_do_arr_strt(pnl_do_arr_strt),
        .pnl_arr_strt_value(pnl_arr_strt_value), .pnl_do_arr_sel(pnl_do_arr_sel),
        .pnl_arr_sel_value(pnl_arr_sel_value), .pnl_arr_cmp_value(pnl_arr_cmp_value),
        .pnl_input_active(pnl_input_active), .pnl_output_active(pnl_output_active),
        .pnl_op_code(pnl_op_code), .pnl_strt_value(pnl_strt_value),
        .pnl_sel_value(pnl_sel_value), .pnl_reg_c_value(pnl_reg_c_value),
        .pnl_pu_state(pnl_pu_state),
        .eng_rd_req(eng_rd_req), .eng_rd_addr(eng_rd_addr), .eng_rd_data(eng_rd_data),
        .eng_wr_req(eng_wr_req), .eng_wr_addr(eng_wr_addr), .eng_wr_data(eng_wr_data),
        .ctrl_rd_req(ctrl_rd_req), .ctrl_rd_addr(ctrl_rd_addr), .ctrl_rd_data(ctrl_rd_data),
        .ctrl_wr_req(ctrl_wr_req), .ctrl_wr_addr(ctrl_wr_addr), .ctrl_wr_data(ctrl_wr_data),
        .dbg_wr_en(dbg_wr_en), .dbg_wr_addr(dbg_wr_addr), .dbg_wr_data(dbg_wr_data),
        .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data)
    );

    copy_engine #(.MEM_SIZE(2048)) u_eng (
        .clk(clk), .resetn(resetn),
        .cmd_src(cmd_src), .cmd_dst(cmd_dst), .cmd_len(cmd_len), .cmd_go(cmd_go),
        .rd_addr(eng_rd_addr), .rd_req(eng_rd_req), .rd_data(eng_rd_data),
        .wr_addr(eng_wr_addr), .wr_data(eng_wr_data), .wr_req(eng_wr_req),
        .ack_done(ack_done), .ack_err(ack_err),
        .busy(busy), .done(done), .err(err), .err_code(err_code),
        .state(eng_state), .remain(remain)
    );

    engine_ctrl #(
        .ADDR_SRC(A_SRC), .ADDR_DST(A_DST), .ADDR_LEN(A_LEN), .ADDR_GO(A_GO),
        .ADDR_BUSY(A_BUSY), .ADDR_DONE(A_DONE), .ADDR_ERR(A_ERR), .ADDR_ACK(A_ACK)
    ) u_ctrl (
        .clk(clk), .resetn(resetn),
        .ctrl_rd_req(ctrl_rd_req), .ctrl_rd_addr(ctrl_rd_addr), .ctrl_rd_data(ctrl_rd_data),
        .ctrl_wr_req(ctrl_wr_req), .ctrl_wr_addr(ctrl_wr_addr), .ctrl_wr_data(ctrl_wr_data),
        .cmd_src(cmd_src), .cmd_dst(cmd_dst), .cmd_len(cmd_len), .cmd_go(cmd_go),
        .ack_done(ack_done), .ack_err(ack_err),
        .busy(busy), .done(done), .err(err), .err_code(err_code)
    );

    // 停机判据
    reg [11:0] stop_counter;    reg [2:0]  last_pu_state;
    always @(posedge clk) last_pu_state <= pnl_pu_state;
    always @(posedge clk) begin
        if (~resetn) stop_counter <= 12'h000;
        else if (pnl_pu_state == last_pu_state) begin
            if (stop_counter != 12'hfff) stop_counter <= stop_counter + 12'h001;
        end else stop_counter <= 12'h000;
    end
    wire machine_stop = stop_counter == 12'hfff && !pnl_input_active && !pnl_output_active;

    task dbg_fill;
        input [11:0] addr;
        input [30:0] data;
        begin
            @(negedge clk);
            dbg_wr_en = 1'b1; dbg_wr_addr = addr; dbg_wr_data = data;
            @(negedge clk);
            dbg_wr_en = 1'b0;
        end
    endtask

    task dbg_read;
        input  [11:0] addr;
        output [30:0] data;
        begin
            @(negedge clk);
            dbg_rd_addr = addr;
            @(negedge clk); @(negedge clk);
            data = dbg_rd_data;
        end
    endtask

    function [4:0] tape_num;
        input [3:0] d;
        begin
            tape_num = TAPE_NUM0 + {1'b0, d[2:0]};
        end
    endfunction

    task send_sym;
        input [4:0] sym;
        begin
            wait (dev_input_rdy);
            @(negedge clk);
            dev_input_val = 1'b1; dev_input_data = sym;
            wait (!dev_input_rdy);
            @(negedge clk);
            dev_input_val = 1'b0;
        end
    endtask

    task tape_write;
        input [3:0] a3,a2,a1,a0;
        input [3:0] v3,v2,v1,v0;
        begin
            send_sym(tape_num(a3)); send_sym(tape_num(a2));
            send_sym(tape_num(a1)); send_sym(tape_num(a0));
            send_sym(TAPE_SEL); send_sym(TAPE_POS);
            send_sym(tape_num(v3)); send_sym(tape_num(v2));
            send_sym(tape_num(v1)); send_sym(tape_num(v0));
            send_sym(TAPE_WRITE);
        end
    endtask

    initial begin
        resetn = 1'b0;
        core_resetn = 1'b0;
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
        core_resetn = 1'b1;
        @(negedge clk);

        pnl_continuous_input = 1'b1;
        pnl_input_dec = 1'b0;
        pnl_automatic = 1'b0;

        dbg_fill(A_BUSY, 31'd0); dbg_fill(A_DONE, 31'd0);
        dbg_fill(A_ERR,  31'd0); dbg_fill(A_ACK,  31'd0);

        // 源区数据 3,4,5
        dbg_fill(MEM_SRC+12'd0, 31'd3);
        dbg_fill(MEM_SRC+12'd1, 31'd4);
        dbg_fill(MEM_SRC+12'd2, 31'd5);

        // 纸带写命令块参数
        @(negedge clk); pnl_start_input = 1'b1; #4; pnl_start_input = 1'b0;
        tape_write(4'd2,4'd4,4'd0,4'd0, 4'd1,4'd5,4'd0,4'd0); // SRC=1500
        tape_write(4'd2,4'd4,4'd0,4'd1, 4'd3,4'd0,4'd0,4'd0); // DST=3000
        tape_write(4'd2,4'd4,4'd0,4'd2, 4'd0,4'd0,4'd0,4'd3); // LEN=3
        tape_write(4'd2,4'd4,4'd0,4'd3, 4'd0,4'd0,4'd0,4'd1); // GO=1
        @(negedge clk); pnl_stop_input = 1'b1; #4; pnl_stop_input = 1'b0;

        // 桥模型轮询 DONE（不写 ACK）
        guard = 0;
        dbg_read(A_DONE, tmp);
        while (tmp !== 31'd1 && guard < 100000) begin
            @(negedge clk); guard = guard + 1;
            dbg_read(A_DONE, tmp);
        end
        dbg_read(A_DONE, tmp);
        if (tmp === 31'd1) pass = pass + 1; else begin fail = fail + 1; $display("FAIL DONE mirror"); end

        // 校验数据段落位
        dbg_read(MEM_DST+12'd0, r0);
        dbg_read(MEM_DST+12'd1, r1);
        dbg_read(MEM_DST+12'd2, r2);
        if (r0 === 31'd3) pass = pass + 1; else fail = fail + 1;
        if (r1 === 31'd4) pass = pass + 1; else fail = fail + 1;
        if (r2 === 31'd5) pass = pass + 1; else fail = fail + 1;

        // 装入固件轮询子程序 + 常量
        dbg_fill(12'o0000, inst(6'o05, 12'o2405, 12'o2000));
        dbg_fill(12'o0001, inst(6'o01, 12'o2001, 12'o2000));
        dbg_fill(12'o0002, inst(6'o05, 12'o2000, 12'o2002));
        dbg_fill(12'o0003, inst(6'o34, 12'o0000, 12'o0005));
        dbg_fill(12'o0005, inst(6'o05, 12'o2001, 12'o2407));
        dbg_fill(12'o0006, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(12'o2001, dataw(1'b0, 30'd1)); // 阈值=1（尾数 1）：1-1=0，0-1=-1
        dbg_fill(12'o2000, 31'd0);
        dbg_fill(12'o2002, 31'd0);

        // 启动核心（只清核心 PU/IO 残留，不复位引擎/ctrl，保留 DONE 等待 ACK）
        pnl_automatic = 1'b1;
        @(negedge clk); core_resetn = 1'b0; #6; core_resetn = 1'b1;
        @(negedge clk);
        pnl_arr_strt_value = 12'o0000; pnl_do_arr_strt = 1'b1; #4; pnl_do_arr_strt = 1'b0;
        @(negedge clk);
        pnl_clear_pu = 1'b1; #4; pnl_clear_pu = 1'b0;
        @(negedge clk);
        pnl_start_pulse = 1'b1; #4; pnl_start_pulse = 1'b0;

        wait (machine_stop);
        $display("machine stopped, strt=%o op=%o c=%h", pnl_strt_value, pnl_op_code, pnl_reg_c_value);

        // 固件已写 ACK → ctrl 握手 → 引擎回 IDLE，ACK 被消费自清
        if (eng_state === 3'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL engine not IDLE state=%0d", eng_state); end
        dbg_read(A_ACK, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL ACK not cleared=%h", tmp); end
        dbg_read(A_DONE, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL DONE mirror residual=%h", tmp); end

        $display("FW-POLL PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("FW-POLL E2E PASS");
        else           $display("FW-POLL E2E FAIL");

        #10 $finish;
    end

    initial begin
        #500000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
