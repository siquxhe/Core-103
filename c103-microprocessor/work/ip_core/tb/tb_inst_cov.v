/**
 * 指令覆盖 testbench · 位与 / 无条件跳转（引擎搬运后核心目的区执行）
 *
 * 用例 A（AND）：
 *   3000=15(0o17), 3001=6(0o06), 3002=0
 *   0000 +06 3000 3001  ; 3001 = 3000 & 3001 = 6
 *   0001 +05 3001 3002  ; 3002 = 3001
 *   0002 +54 0000 0000  ; 停机
 *   预期 3001=6, 3002=6
 *
 * 用例 B（BRANCH，+24 无条件跳 c1）：
 *   3000=42, 3001=0, 3002=0
 *   0000 +24 0002 2000  ; pc=0002，跳过 0001
 *   0001 +05 3000 3001  ; 被跳过，不执行
 *   0002 +05 3000 3002  ; 3002 = 3000
 *   0003 +54 0000 0000  ; 停机
 *   预期 3001=0（未被写），3002=42
 *
 * 定点 1.30：值 = 尾数 / 2^30。
 * 用例 C（MUL，+03）：a=b=1/2（尾数 2^29），(b*a)>>30 = 1/4（尾数 2^28）
 *   0000 +03 3000 3001  ; 3001 = a*b = 1/4
 *   0001 +05 3001 3002  ; 3002 = 3001
 *   0002 +54 0000 0000  ; 停机
 *   预期 3001=2^28, 3002=2^28
 *
 * 用例 D（DIV，+02）：a=1/2（尾数 2^29），b=1/4（尾数 2^28），(b<<30)/a = 1/2（尾数 2^29）
 *   0000 +02 3000 3001  ; 3001 = b/a = 1/2
 *   0001 +05 3001 3002  ; 3002 = 3001
 *   0002 +54 0000 0000  ; 停机
 *   预期 3001=2^29, 3002=2^29
 *
 * 用例 E（COND-BRANCH，+34，b 非负 → pc=c2）：
 *   3000=+42；0000 传送置 b=+42；0001 +34 0003 0002（非负走 c2=0002）
 *   0002 写 3002=42；0003 汇合停机；预期 3002=42
 *
 * 用例 F（COND-BRANCH，+34，b 为负 → pc=c1=0003 停机）：
 *   3000=-1/2（word=0x60000000）；0000 传送置 b=负；0001 +34 0003 0002
 *   负走 c1=0003 停机，3002 未写；预期 3002=0
 */

`timescale 1ns/1ps

module tb_inst_cov;

    reg clk;
    reg resetn;

    // dev
    wire        dev_input_rdy;
    reg         dev_input_val;
    wire        dev_output_rdy;
    reg         dev_output_ack;
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

    // 停机判据
    reg [11:0] stop_counter;
    reg [2:0]  last_pu_state;
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
        dev_input_val = 0; dev_output_ack = 0; dev_input_data = 5'd0;
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

        // ---- 用例 A：AND ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o06, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o05, 12'o3001, 12'o3002));
        dbg_fill(P_SRC+2, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd15));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd6));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd3);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd6, "AND-3001");
        check_mem(12'o3002, 31'd6, "AND-3002");

        // ---- 用例 B：BRANCH ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o24, 12'o0002, 12'o2000));
        dbg_fill(P_SRC+1, inst(6'o05, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+2, inst(6'o05, 12'o3000, 12'o3002));
        dbg_fill(P_SRC+3, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd42));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd4);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd0,   "BR-3001-skip");
        check_mem(12'o3002, 31'd42,  "BR-3002");

        // ---- 用例 C：MUL  1/2 * 1/2 = 1/4 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o03, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o05, 12'o3001, 12'o3002));
        dbg_fill(P_SRC+2, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd536870912)); // 2^29 = 1/2
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd536870912)); // 2^29 = 1/2
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd3);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd268435456, "MUL-3001=1/4");
        check_mem(12'o3002, 31'd268435456, "MUL-3002=1/4");

        // ---- 用例 D：DIV  (1/4) / (1/2) = 1/2 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o02, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o05, 12'o3001, 12'o3002));
        dbg_fill(P_SRC+2, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd536870912)); // 2^29 = 1/2 (a)
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd268435456)); // 2^28 = 1/4 (b)
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd3);
        do_copy(D_SRC, D_DST, 12'd3);
        launch(12'o0000);
        check_mem(12'o3001, 31'd536870912, "DIV-3001=1/2");
        check_mem(12'o3002, 31'd536870912, "DIV-3002=1/2");

        // ---- 用例 E：COND-BRANCH，b 非负 -> pc=c2 ----
        //   0001 +34 0003 0002：非负走 c2=0002 写 3002；0003 为汇合停机
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o05, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o34, 12'o0003, 12'o0002));
        dbg_fill(P_SRC+2, inst(6'o05, 12'o3000, 12'o3002));
        dbg_fill(P_SRC+3, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b0, 30'd42));
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+3, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd4);
        do_copy(D_SRC, D_DST, 12'd4);
        launch(12'o0000);
        check_mem(12'o3002, 31'd42, "CBR-POS-3002");

        // ---- 用例 F：COND-BRANCH，b 为负 -> pc=c1=0003 停机，3002 未写 ----
        reset_core;
        dbg_fill(P_SRC+0, inst(6'o05, 12'o3000, 12'o3001));
        dbg_fill(P_SRC+1, inst(6'o34, 12'o0003, 12'o0002));
        dbg_fill(P_SRC+2, inst(6'o05, 12'o3000, 12'o3002));
        dbg_fill(P_SRC+3, inst(6'o54, 12'o0000, 12'o0000));
        dbg_fill(D_SRC+0, dataw(1'b1, 30'd536870912)); // -1/2：word=0x60000000
        dbg_fill(D_SRC+1, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
        dbg_fill(D_SRC+3, dataw(1'b0, 30'd0));
        do_copy(P_SRC, P_DST, 12'd4);
        do_copy(D_SRC, D_DST, 12'd4);
        launch(12'o0000);
        check_mem(12'o3002, 31'd0, "CBR-NEG-3002-skip");

        $display("INST-COV PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("INST-COV PASS");
        else           $display("INST-COV FAIL");
        #10 $finish;
    end

    initial begin #200000; $display("FAIL global timeout"); $finish; end

endmodule
