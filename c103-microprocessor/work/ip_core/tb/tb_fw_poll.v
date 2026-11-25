/**
 * 核心固件轮询 testbench · 固件程序 / 常量段经引擎搬运装入，核心读命令块状态、
 * 循环等待 done、写 ACK
 *
 * 装载编排（调试口仅把程序 / 数据预存到介质源区模拟外部介质，运行区一律由引擎
 * 经命令块搬运装入）：
 *  1. 介质源区预存：程序段 1200、常量段 1600、数据段 1500；
 *  2. 第一轮：引擎搬程序段 1200 -> 0000，桥模型代写 ACK drain 握手回 IDLE；
 *  3. 第二轮：引擎搬常量段 1600 -> 2000，drain 握手回 IDLE；
 *  4. 第三轮：引擎搬数据段 1500 -> 3000；本轮不 drain，ctrl 停在 S_DONE 等 ACK，
 *     DONE 镜像保持 1，作为随后启动的固件轮询目标；
 *  5. 启动核心：固件读 STS_DONE，减法判符号，条件跳转循环；完成后写 CMD_ACK；
 *  6. ctrl 收到 ACK 向引擎发 ack_done，引擎回 IDLE，ACK / DONE 镜像自清。
 *
 * 判据：三段目的区逐字落位（与源快照比对）；第三轮 DONE 镜像=1；核心停机；
 * 引擎回 IDLE、ACK / DONE 镜像自清（即固件已写 ACK 并完成握手）。
 *
 * 固件子程序（目的区，八进制地址；连续 6 字，034 非负跳转目标为 0004）：
 *   2001 = 尾数 1（减法阈值：1-1=0 非负，0-1=-1 为负）
 *   0000 +05 2405 2000  ; b = mem[DONE=2405]; mem[2000]=DONE
 *   0001 +01 2001 2000  ; c = b(2000) - a(2001=1)，存 2000
 *   0002 +05 2000 2002  ; b = c = 差值; mem[2002]=差值
 *   0003 +34 0000 0004  ; b 负(未完成)→0000 循环；非负(完成)→0004
 *   0004 +05 2001 2407  ; mem[ACK=2407]=1（非 0 即握手）
 *   0005 +54 0000 0000  ; 停机
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

    // 介质源区（外部介质预存，调试口仅在此阶段写入模拟装入）与运行区目的地址
    localparam [11:0] DATA_SRC  = 12'o1500;  // 数据段源
    localparam [11:0] DATA_DST  = 12'o3000;  // 数据段目的
    localparam [11:0] CODE_SRC  = 12'o1200;  // 固件程序段源
    localparam [11:0] CODE_DST  = 12'o0000;  // 固件程序段目的
    localparam [11:0] CONST_SRC = 12'o1600;  // 固件常量段源
    localparam [11:0] CONST_DST= 12'o2000;  // 固件常量段目的
    localparam [11:0] DLEN = 12'd3;
    localparam [11:0] CLEN = 12'd6;
    localparam [11:0] KLEN = 12'd3;

    localparam [4:0] TAPE_SEL  = 5'h01;
    localparam [4:0] TAPE_POS  = 5'h1E;
    localparam [4:0] TAPE_WRITE= 5'h06;
    localparam [4:0] TAPE_NUM0 = 5'h10;

    integer pass, fail;
    reg [30:0] r0, r1, r2, tmp;
    integer guard;

    // 程序段 / 常量段期望快照（预填期记录，搬运后回读目的区逐字比对）
    reg [30:0] code_exp  [0:5];
    reg [30:0] const_exp [0:2];
    reg        round_ok;
    integer i;

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

    // 12 位八进制地址 / 数值拆 4 位八进制，经纸带写一个命令块字
    task write_cmd_word;
        input  [11:0] addr;
        input  [11:0] value;
        begin
            tape_write(addr[11:9], addr[8:6], addr[5:3], addr[2:0],
                       value[11:9], value[8:6], value[5:3], value[2:0]);
        end
    endtask

    // 一轮引擎搬运：纸带写命令块 SRC/DST/LEN/GO，由 ctrl 装配并启动引擎
    task issue_copy;
        input [11:0] src, dst, len;
        begin
            @(negedge clk);
            pnl_start_input = 1'b1; #4; pnl_start_input = 1'b0;
            write_cmd_word(A_SRC, src);
            write_cmd_word(A_DST, dst);
            write_cmd_word(A_LEN, len);
            write_cmd_word(A_GO,  12'd1);
            @(negedge clk);
            pnl_stop_input = 1'b1; #4; pnl_stop_input = 1'b0;
        end
    endtask

    // 轮询 DONE 镜像置 1；ok=1 表示在护栏内等到完成
    task wait_done;
        output        ok;
        output [30:0] done_val;
        begin
            guard = 0;
            dbg_read(A_DONE, done_val);
            while (done_val !== 31'd1 && guard < 100000) begin
                @(negedge clk);
                guard = guard + 1;
                dbg_read(A_DONE, done_val);
            end
            ok = (done_val === 31'd1);
        end
    endtask

    // 桥模型代写 ACK，等 ctrl 消费自清、引擎回 IDLE
    task ack_drain;
        output idle_ok;
        begin
            dbg_fill(A_ACK, 31'd1);
            guard = 0;
            dbg_read(A_ACK, tmp);
            while (tmp !== 31'd0 && guard < 100000) begin
                @(negedge clk);
                guard = guard + 1;
                dbg_read(A_ACK, tmp);
            end
            idle_ok = (tmp === 31'd0) && (eng_state === 3'd0);
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

        // ---- 介质源区预存（调试口仅模拟外部介质输入，不直写运行区） ----
        // 数据段 3,4,5
        dbg_fill(DATA_SRC+12'd0, 31'd3);
        dbg_fill(DATA_SRC+12'd1, 31'd4);
        dbg_fill(DATA_SRC+12'd2, 31'd5);

        // 固件程序段（连续 6 字，重排消除 0004 空洞；034 非负跳转目标改 0004）
        code_exp[0] = inst(6'o05, 12'o2405, 12'o2000);
        code_exp[1] = inst(6'o01, 12'o2001, 12'o2000);
        code_exp[2] = inst(6'o05, 12'o2000, 12'o2002);
        code_exp[3] = inst(6'o34, 12'o0000, 12'o0004);
        code_exp[4] = inst(6'o05, 12'o2001, 12'o2407);
        code_exp[5] = inst(6'o54, 12'o0000, 12'o0000);
        for (i=0; i<6; i=i+1) dbg_fill(CODE_SRC+i, code_exp[i]);

        // 固件常量段：2000 暂存 0、2001 阈值尾数 1、2002 暂存 0
        const_exp[0] = 31'd0;
        const_exp[1] = dataw(1'b0, 30'd1);
        const_exp[2] = 31'd0;
        for (i=0; i<3; i=i+1) dbg_fill(CONST_SRC+i, const_exp[i]);

        // ---- 第一轮：固件程序段 1200 -> 0000（引擎装入程序区，装完 drain 握手） ----
        issue_copy(CODE_SRC, CODE_DST, CLEN);
        wait_done(round_ok, tmp);
        if (round_ok) pass = pass + 1; else begin fail = fail + 1; $display("FAIL code DONE mirror"); end
        for (i=0; i<6; i=i+1) begin
            dbg_read(CODE_DST+i, tmp);
            if (tmp === code_exp[i]) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL code[%0d]=%h expect %h", i, tmp, code_exp[i]); end
        end
        ack_drain(round_ok);
        if (!round_ok) begin fail = fail + 1; $display("FAIL code round ack drain"); end

        // ---- 第二轮：固件常量段 1600 -> 2000（装完 drain 握手） ----
        issue_copy(CONST_SRC, CONST_DST, KLEN);
        wait_done(round_ok, tmp);
        if (round_ok) pass = pass + 1; else begin fail = fail + 1; $display("FAIL const DONE mirror"); end
        for (i=0; i<3; i=i+1) begin
            dbg_read(CONST_DST+i, tmp);
            if (tmp === const_exp[i]) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL const[%0d]=%h expect %h", i, tmp, const_exp[i]); end
        end
        ack_drain(round_ok);
        if (!round_ok) begin fail = fail + 1; $display("FAIL const round ack drain"); end

        // ---- 第三轮：数据段 1500 -> 3000（固件最终服务的任务；不 drain，
        //      ctrl 停在 S_DONE 等 ACK，DONE 镜像保持 1 供随后启动的固件轮询） ----
        issue_copy(DATA_SRC, DATA_DST, DLEN);
        wait_done(round_ok, tmp);
        if (round_ok) pass = pass + 1; else begin fail = fail + 1; $display("FAIL data DONE mirror"); end
        dbg_read(DATA_DST+12'd0, r0);
        dbg_read(DATA_DST+12'd1, r1);
        dbg_read(DATA_DST+12'd2, r2);
        if (r0 === 31'd3) pass = pass + 1; else fail = fail + 1;
        if (r1 === 31'd4) pass = pass + 1; else fail = fail + 1;
        if (r2 === 31'd5) pass = pass + 1; else fail = fail + 1;

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
