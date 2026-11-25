/**
 * 传送变体指令覆盖 testbench（引擎搬运后核心目的区执行）
 *
 * 对齐 C 模拟器 103.c 分支语义：
 *   005 / 015 : reg_c=mem[c1]; mem[c2]=reg_c; reg_b=reg_c;            （传送，不输出）
 *   045 / 055 : reg_c=mem[c1]; mem[c2]=reg_c; do_output_reg_c();     （传送 + 输出）
 *   064       : reg_pc=c1; mem[c2]=reg_b; do_output_reg_c();         （跳转 + b→c2 + 输出）
 *
 * 用例（数据区 3000..3002，程序区 0000 起；定点 1.30 小整数尾数）：
 *   M1 op005 : 3000=11 ; 0000 +05 3000 3001 ; 预期 3001=11
 *   M2 op015 : 3000=22 ; 0000 +15 3000 3001 ; 预期 3001=22
 *   M3 op045 : 3000=33 ; 0000 +45 3000 3001 ; 预期 3001=33（输出一次）
 *   M4 op055 : 3000=44 ; 0000 +55 3000 3001 ; 预期 3001=44（输出一次）
 *   M5 op064 : 3000=55 ; 0000 +05 3000 3001（b=55）
 *                          0001 +64 0003 3002（pc=0003, 3002=b=55, 输出）
 *                          0002 +54 0000 0000（被跳过）
 *                          0003 +54 0000 0000（停机）
 *              预期 3002=55
 *
 * 输出类用例由 sim_output 模型自主完成 dev 输出握手；输入链路不启用。
 */

`timescale 1ns/1ps

module tb_move_cov;

    reg clk;
    reg resetn;

    // dev（输入不启用；输出接 sim_output 自主握手）
    wire        dev_input_rdy;
    reg         dev_input_val;
    wire        dev_output_rdy;
    wire        dev_output_ack;
    reg  [4:0]  dev_input_data;
    wire [4:0]  dev_output_data;

    // pnl
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

    // engine
    reg  [11:0] cmd_src, cmd_dst, cmd_len;
    reg         cmd_go;
    reg         ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  state;
    wire [11:0] remain;
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;

    // dbg
    reg         dbg_wr_en;
    reg  [11:0] dbg_wr_addr, dbg_rd_addr;
    reg  [30:0] dbg_wr_data;
    wire [30:0] dbg_rd_data;

    localparam [11:0] P_SRC = 12'o1000;
    localparam [11:0] D_SRC = 12'o1500;
    localparam [11:0] P_DST = 12'o0000;
    localparam [11:0] D_DST = 12'o3000;

    reg [11:0] stop_counter;
    reg [2:0]  last_pu_state;
    integer pass, fail;

    initial clk = 1'b0;
    always #1 clk = ~clk;

    function [30:0] inst;
        input [5:0]  op;
        input [11:0] c1;
        input [11:0] c2;
        begin inst = {1'b0, op, c1, c2}; end
    endfunction

    function [30:0] dataw;
        input        sign;
        input [29:0] val;
        begin dataw = {sign, val}; end
    endfunction

    core_top u_core (
        .clk(clk), .resetn(resetn),
        .dev_input_rdy(dev_input_rdy), .dev_input_val(dev_input_val),
        .dev_output_rdy(dev_output_rdy), .dev_output_ack(dev_output_ack),
        .dev_input_data(dev_input_data), .dev_output_data(dev_output_data),
        .pnl_start_pulse(pnl_start_pulse), .pnl_clear_pu(pnl_clear_pu),
        .pnl_automatic(pnl_automatic),
        .pnl_mem_read(pnl_mem_read), .pnl_mem_write(pnl_mem_write),
        .pnl_start_input(pnl_start_input), .pnl_stop_input(pnl_stop_input),
        .pnl_start_output(pnl_start_output), .pnl_stop_output(pnl_stop_output),
        .pnl_input_dec(pnl_input_dec), .pnl_output_dec(pnl_output_dec),
        .pnl_continuous_input(pnl_continuous_input),
        .pnl_stop_after_output(pnl_stop_after_output),
        .pnl_stop_at_cmp(pnl_stop_at_cmp), .pnl_cmp_with_strt(pnl_cmp_with_strt),
        .pnl_do_arr_c(pnl_do_arr_c), .pnl_arr_reg_c_value(pnl_arr_reg_c_value),
        .pnl_do_arr_strt(pnl_do_arr_strt), .pnl_arr_strt_value(pnl_arr_strt_value),
        .pnl_do_arr_sel(pnl_do_arr_sel), .pnl_arr_sel_value(pnl_arr_sel_value),
        .pnl_arr_cmp_value(pnl_arr_cmp_value),
        .pnl_input_active(pnl_input_active), .pnl_output_active(pnl_output_active),
        .pnl_op_code(pnl_op_code), .pnl_strt_value(pnl_strt_value),
        .pnl_sel_value(pnl_sel_value), .pnl_reg_c_value(pnl_reg_c_value),
        .pnl_pu_state(pnl_pu_state),
        .eng_rd_req(eng_rd_req), .eng_rd_addr(eng_rd_addr), .eng_rd_data(eng_rd_data),
        .eng_wr_req(eng_wr_req), .eng_wr_addr(eng_wr_addr), .eng_wr_data(eng_wr_data),
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
        .state(state), .remain(remain)
    );

    // 输出自主握手模型（输入链路悬空，不例化 sim_input）
    sim_output u_sim_output (
        .clk(clk), .resetn(resetn),
        .output_rdy(dev_output_rdy),
        .output_data(dev_output_data),
        .output_ack(dev_output_ack)
    );

    // 停机判据
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

    task do_copy;
        input [11:0] src, dst, len;
        begin
            @(negedge clk);
            cmd_src = src; cmd_dst = dst; cmd_len = len; cmd_go = 1'b1;
            @(negedge clk); cmd_go = 1'b0;
            wait (done || err);
            if (err) begin $display("FAIL engine err=%0d", err_code); fail = fail + 1; end
            @(negedge clk); ack_done = 1'b1;
            @(negedge clk); ack_done = 1'b0;
        end
    endtask

    task launch;
        input [11:0] entry;
        begin
            @(negedge clk);
            pnl_arr_strt_value = entry; pnl_do_arr_strt = 1'b1; #4; pnl_do_arr_strt = 1'b0;
            @(negedge clk);
            pnl_clear_pu = 1'b1; #4; pnl_clear_pu = 1'b0;
            @(negedge clk);
            pnl_start_pulse = 1'b1; #4; pnl_start_pulse = 1'b0;
            wait (machine_stop);
        end
    endtask

    task check_mem;
        input [11:0] addr;
        input [30:0] expect;
        input [8*16-1:0] tag;
        reg [30:0] got;
        begin
            dbg_rd_addr = addr;
            @(negedge clk); @(negedge clk);
            got = dbg_rd_data;
            if (got === expect) begin
                pass = pass + 1;
                $display("PASS %s: mem[%o]=%h", tag, addr, got);
            end else begin
                fail = fail + 1;
                $display("FAIL %s: mem[%o]=%h expect %h", tag, addr, got, expect);
            end
        end
    endtask

    task reset_core;
        begin
            @(negedge clk); resetn = 1'b0; #6; resetn = 1'b1;
            @(negedge clk);
        end
    endtask

    initial begin
        dev_input_val = 0; dev_input_data = 5'd0;
        pnl_start_pulse = 0; pnl_clear_pu = 0; pnl_automatic = 1;
        pnl_mem_read = 0; pnl_mem_write = 0;
        pnl_start_input = 0; pnl_stop_input = 0;
        pnl_start_output = 0; pnl_stop_output = 0;
        pnl_input_dec = 0; pnl_output_dec = 0;
        pnl_continuous_input = 0; pnl_stop_after_output = 0;
        pnl_stop_at_cmp = 0; pnl_cmp_with_strt = 0;
        pnl_do_arr_c = 0; pnl_arr_reg_c_value = 0;
        pnl_do_arr_strt = 0; pnl_arr_strt_value = 0;
        pnl_do_arr_sel = 0; pnl_arr_sel_value = 0; pnl_arr_cmp_value = 0;
        cmd_src = 0; cmd_dst = 0; cmd_len = 0; cmd_go = 0;
        ack_done = 0; ack_err = 0;
        dbg_wr_en = 0; dbg_wr_addr = 0; dbg_wr_data = 0; dbg_rd_addr = 0;
        pass = 0; fail = 0;

        // ---- M1：op005 传送 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o05, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd11));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd2);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd11, "M1-005-3001");

        // ---- M2：op015 传送 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o15, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd22));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd2);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd22, "M2-015-3001");

        // ---- M3：op045 传送 + 输出 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o45, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd33));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd2);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd33, "M3-045-3001");

        // ---- M4：op055 传送 + 输出 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o55, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd44));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd2);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd44, "M4-055-3001");

        // ---- M5：op064 跳转 + b→c2 + 输出 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o05, 12'o3000, 12'o3001)); // b=mem[3000]=55
        dbg_fill(P_SRC+1, inst(6'o64, 12'o0003, 12'o3002)); // pc=0003, 3002=b
        dbg_fill(P_SRC+2, inst(6'o54, 12'o0000, 12'o0000)); // 被跳过
        dbg_fill(P_SRC+3, inst(6'o54, 12'o0000, 12'o0000)); // 停机
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd55));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd4);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3002, 31'd55, "M5-064-3002");

        $display("MOVE-COV PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("MOVE-COV PASS");
        else           $display("MOVE-COV FAIL");
        #10 $finish;
    end

    initial begin #200000; $display("FAIL global timeout"); $finish; end

endmodule
