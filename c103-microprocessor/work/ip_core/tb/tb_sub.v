/**
 * 减法指令覆盖 testbench · op=01（定点 1.30，尾数小整数直放）
 *
 * C do_sub: res = sign_b*num_b - sign_a*num_a；结果存 c2（b 所在单元）。
 *   res>0 尾数正；res<0 置 bit30 负号；res==0 符号取 sign_b。
 * 指令：+01 c1 c2；a=mem[c1]，b=mem[c2]，res 写回 mem[c2]。
 *
 * 用例（尾数取小整数，不触发 ±0x3fffffff 溢出）：
 *   S1 正-正：a=+3, b=+5 -> +2
 *   S2 正-正得负：a=+5, b=+3 -> -2
 *   S3 负-正：a=-3, b=+5 -> +8 （5-(-3)）
 *   S4 正-负：a=+5, b=-3 -> -8 （-3-5）
 *   S5 负-负：a=-5, b=-3 -> +2 （-3-(-5)）
 *   S6 零结果(正b)：a=+4, b=+4 -> 0（正）
 *   S7 零结果(负b)：a=-4, b=-4 -> 负号 + 0
 */

`timescale 1ns/1ps

module tb_sub;

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

    localparam [30:0] NEG = 31'h40000000;

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

    // 单个减法用例：a=mem3000, b=mem3001, res 回 3001，拷贝到 3002
    task run_sub;
        input [30:0] a_word;
        input [30:0] b_word;
        input [30:0] expect_res;
        input [8*16-1:0] tag;
        begin
            reset_core;
            dbg_fill(P_SRC+0, inst(6'o01, 12'o3000, 12'o3001));
            dbg_fill(P_SRC+1, inst(6'o05, 12'o3001, 12'o3002));
            dbg_fill(P_SRC+2, inst(6'o54, 12'o0000, 12'o0000));
            dbg_fill(D_SRC+0, a_word);
            dbg_fill(D_SRC+1, b_word);
            dbg_fill(D_SRC+2, dataw(1'b0, 30'd0));
            do_copy(P_SRC, P_DST, 12'd3);
            do_copy(D_SRC, D_DST, 12'd3);
            launch(12'o0000);
            check_mem(12'o3001, expect_res, tag);
            check_mem(12'o3002, expect_res, {tag, "-copy"});
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

        // S1 正-正 = +2
        run_sub(dataw(1'b0, 30'd3),  dataw(1'b0, 30'd5),  31'd2,              "SUB-S1");
        // S2 正-正得负 = -2
        run_sub(dataw(1'b0, 30'd5),  dataw(1'b0, 30'd3),  NEG | 31'd2,       "SUB-S2");
        // S3 负-正 = +8
        run_sub(dataw(1'b1, 30'd3),  dataw(1'b0, 30'd5),  31'd8,              "SUB-S3");
        // S4 正-负 = -8
        run_sub(dataw(1'b0, 30'd5),  dataw(1'b1, 30'd3),  NEG | 31'd8,       "SUB-S4");
        // S5 负-负 = +2
        run_sub(dataw(1'b1, 30'd5),  dataw(1'b1, 30'd3),  31'd2,              "SUB-S5");
        // S6 零结果，b 正 -> 正 0
        run_sub(dataw(1'b0, 30'd4),  dataw(1'b0, 30'd4),  31'd0,              "SUB-S6");
        // S7 零结果，b 负 -> 负号 + 0
        run_sub(dataw(1'b1, 30'd4),  dataw(1'b1, 30'd4),  NEG,                "SUB-S7");

        $display("SUB-COV PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("SUB-COV PASS");
        else           $display("SUB-COV FAIL");
        #10 $finish;
    end

    initial begin #300000; $display("FAIL global timeout"); $finish; end

endmodule
