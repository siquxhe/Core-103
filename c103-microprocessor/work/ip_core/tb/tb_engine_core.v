/**
 * 2b 端到端 testbench · 引擎搬运后核心从目的区取指执行
 *
 * 场景（最小加法程序）：
 *  1. 调试口把程序段 / 数据段预填到源区；
 *  2. 引擎两段搬运：程序段 → 目的区 0000 起，数据段 → 目的区 3000 起；
 *  3. arr_strt 预置入口 0000，clear_pu + start_pulse 启动核心；
 *  4. 停机后调试口读结果单元，校验 3001 / 3002 == 7（3 + 4）。
 *
 * 程序（目的区）：
 *  0000: +00 3000 3001   ; mem[3001] = mem[3000] + mem[3001] = 3+4
 *  0001: +05 3001 3002   ; mem[3002] = mem[3001]
 *  0002: +54 0000 0000   ; 停机
 * 数据：3000=3, 3001=4, 3002=0
 */

`timescale 1ns/1ps

module tb_engine_core;

    // ---- 时钟 / 复位 ----
    reg clk;
    reg resetn;

    // ---- dev 握手 ----
    wire        dev_input_rdy;
    reg         dev_input_val;
    wire        dev_output_rdy;
    reg         dev_output_ack;
    reg  [4:0]  dev_input_data;
    wire [4:0]  dev_output_data;

    // ---- 面板脉冲 / 电平 ----
    reg         pnl_start_pulse;
    reg         pnl_clear_pu;
    reg         pnl_automatic;
    reg         pnl_mem_read;
    reg         pnl_mem_write;
    reg         pnl_start_input;
    reg         pnl_stop_input;
    reg         pnl_start_output;
    reg         pnl_stop_output;
    reg         pnl_input_dec;
    reg         pnl_output_dec;
    reg         pnl_continuous_input;
    reg         pnl_stop_after_output;
    reg         pnl_stop_at_cmp;
    reg         pnl_cmp_with_strt;
    reg         pnl_do_arr_c;
    reg  [30:0] pnl_arr_reg_c_value;
    reg         pnl_do_arr_strt;
    reg  [11:0] pnl_arr_strt_value;
    reg         pnl_do_arr_sel;
    reg  [11:0] pnl_arr_sel_value;
    reg  [11:0] pnl_arr_cmp_value;

    // ---- 面板观测 ----
    wire        pnl_input_active;
    wire        pnl_output_active;
    wire [5:0]  pnl_op_code;
    wire [11:0] pnl_strt_value;
    wire [11:0] pnl_sel_value;
    wire [30:0] pnl_reg_c_value;
    wire [2:0]  pnl_pu_state;

    // ---- 引擎命令 / 握手 ----
    reg  [11:0] cmd_src, cmd_dst, cmd_len;
    reg         cmd_go;
    reg         ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  state;
    wire [11:0] remain;

    // ---- 引擎 ↔ memory 旁路 ----
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;

    // ---- 调试口 ----
    reg         dbg_wr_en;
    reg  [11:0] dbg_wr_addr, dbg_rd_addr;
    reg  [30:0] dbg_wr_data;
    wire [30:0] dbg_rd_data;

    // ---- 地址 / 长度常量（八进制） ----
    localparam [11:0] P_SRC  = 12'o1000;
    localparam [11:0] D_SRC  = 12'o1500;
    localparam [11:0] P_DST  = 12'o0000;
    localparam [11:0] D_DST  = 12'o3000;
    localparam [11:0] PLEN   = 12'd3;
    localparam [11:0] DLEN    = 12'd3;

    integer pass, fail;
    reg [30:0] r3001, r3002;

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #1 clk = ~clk;

    // ---- 指令 / 数据字编码 ----
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

    // ---- DUT：核心 ----
    core_top u_core (
        .clk                     ( clk                     ),
        .resetn                  ( resetn                  ),
        .dev_input_rdy           ( dev_input_rdy           ),
        .dev_input_val           ( dev_input_val           ),
        .dev_output_rdy          ( dev_output_rdy          ),
        .dev_output_ack          ( dev_output_ack         ),
        .dev_input_data          ( dev_input_data         ),
        .dev_output_data         ( dev_output_data        ),
        .pnl_start_pulse         ( pnl_start_pulse        ),
        .pnl_clear_pu            ( pnl_clear_pu           ),
        .pnl_automatic           ( pnl_automatic          ),
        .pnl_mem_read            ( pnl_mem_read           ),
        .pnl_mem_write           ( pnl_mem_write          ),
        .pnl_start_input         ( pnl_start_input        ),
        .pnl_stop_input          ( pnl_stop_input         ),
        .pnl_start_output        ( pnl_start_output       ),
        .pnl_stop_output         ( pnl_stop_output        ),
        .pnl_input_dec           ( pnl_input_dec          ),
        .pnl_output_dec          ( pnl_output_dec        ),
        .pnl_continuous_input    ( pnl_continuous_input   ),
        .pnl_stop_after_output   ( pnl_stop_after_output  ),
        .pnl_stop_at_cmp         ( pnl_stop_at_cmp        ),
        .pnl_cmp_with_strt       ( pnl_cmp_with_strt      ),
        .pnl_do_arr_c            ( pnl_do_arr_c           ),
        .pnl_arr_reg_c_value     ( pnl_arr_reg_c_value    ),
        .pnl_do_arr_strt         ( pnl_do_arr_strt        ),
        .pnl_arr_strt_value      ( pnl_arr_strt_value    ),
        .pnl_do_arr_sel          ( pnl_do_arr_sel         ),
        .pnl_arr_sel_value       ( pnl_arr_sel_value     ),
        .pnl_arr_cmp_value       ( pnl_arr_cmp_value     ),
        .pnl_input_active        ( pnl_input_active       ),
        .pnl_output_active       ( pnl_output_active      ),
        .pnl_op_code             ( pnl_op_code            ),
        .pnl_strt_value          ( pnl_strt_value         ),
        .pnl_sel_value           ( pnl_sel_value         ),
        .pnl_reg_c_value         ( pnl_reg_c_value        ),
        .pnl_pu_state            ( pnl_pu_state           ),

        .eng_rd_req              ( eng_rd_req             ),
        .eng_rd_addr             ( eng_rd_addr            ),
        .eng_rd_data             ( eng_rd_data            ),
        .eng_wr_req              ( eng_wr_req             ),
        .eng_wr_addr             ( eng_wr_addr           ),
        .eng_wr_data             ( eng_wr_data            ),
        .dbg_wr_en               ( dbg_wr_en              ),
        .dbg_wr_addr             ( dbg_wr_addr            ),
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
        .ack_err        ( ack_err      ),
        .busy           ( busy         ),
        .done           ( done         ),
        .err            ( err          ),
        .err_code       ( err_code     ),
        .state          ( state        ),
        .remain         ( remain       )
    );

    // ---- 停机判据：PU 状态静止且无 IO 活动 ----
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

    // ---- 调试写一字 ----
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

    // ---- 一次搬运 ----
    task do_copy;
        input [11:0] src;
        input [11:0] dst;
        input [11:0] len;
        begin
            @(negedge clk);
            cmd_src = src; cmd_dst = dst; cmd_len = len; cmd_go = 1'b1;
            @(negedge clk);
            cmd_go = 1'b0;
            wait (done || err);
            if (err) begin
                $display("FAIL engine err_code=%0d", err_code);
                fail = fail + 1;
            end else begin
                $display("copy done src=%o dst=%o len=%o remain=%o", src, dst, len, remain);
            end
            @(negedge clk);
            ack_done = 1'b1;
            @(negedge clk);
            ack_done = 1'b0;
        end
    endtask

    // ---- 备查波形 ----
    initial begin
        $dumpfile("tb_ec.vcd");
        $dumpvars(0, tb_engine_core);
    end

    // ---- 主流程 ----
    initial begin
        // 输入默认值
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
        pnl_do_arr_sel = 0; pnl_arr_sel_value = 0; pnl_arr_cmp_value = 0;
        cmd_src = 0; cmd_dst = 0; cmd_len = 0; cmd_go = 0;
        ack_done = 0; ack_err = 0;
        dbg_wr_en = 0; dbg_wr_addr = 0; dbg_wr_data = 0; dbg_rd_addr = 0;
        pass = 0; fail = 0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // 1) 预填源区：程序段
        dbg_fill(P_SRC + 12'd0, inst(6'o00, 12'o3000, 12'o3001));
        dbg_fill(P_SRC + 12'd1, inst(6'o05, 12'o3001, 12'o3002));
        dbg_fill(P_SRC + 12'd2, inst(6'o54, 12'o0000, 12'o0000));
        // 数据段
        dbg_fill(D_SRC + 12'd0, dataw(1'b0, 30'd3));
        dbg_fill(D_SRC + 12'd1, dataw(1'b0, 30'd4));
        dbg_fill(D_SRC + 12'd2, dataw(1'b0, 30'd0));

        // 2) 引擎两段搬运
        do_copy(P_SRC, P_DST, PLEN);
        do_copy(D_SRC, D_DST, DLEN);

        // 3) 预置入口 0000
        @(negedge clk);
        pnl_arr_strt_value = 12'o0000;
        pnl_do_arr_strt    = 1'b1;
        #4;
        pnl_do_arr_strt    = 1'b0;

        // 4) clear PU → start
        @(negedge clk);
        pnl_clear_pu = 1'b1;
        #4;
        pnl_clear_pu = 1'b0;

        @(negedge clk);
        pnl_start_pulse = 1'b1;
        #4;
        pnl_start_pulse = 1'b0;

        // 5) 等待停机
        wait (machine_stop);
        $display("machine stopped, strt=%o op=%o c=%h", pnl_strt_value, pnl_op_code, pnl_reg_c_value);

        // 6) 校验结果
        dbg_rd_addr = 12'o3002;
        @(negedge clk); @(negedge clk);
        r3002 = dbg_rd_data;
        dbg_rd_addr = 12'o3001;
        @(negedge clk); @(negedge clk);
        r3001 = dbg_rd_data;

        $display("mem[3001]=%h  mem[3002]=%h  expect 7", r3001, r3002);
        if (r3001 === 31'd7) begin pass = pass + 1; end else begin fail = fail + 1; end
        if (r3002 === 31'd7) begin pass = pass + 1; end else begin fail = fail + 1; end

        $display("ENGINE-CORE PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("ENGINE-CORE E2E PASS");
        else           $display("ENGINE-CORE E2E FAIL");

        #10 $finish;
    end

    // ---- 全局超时兜底 ----
    initial begin
        #200000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
