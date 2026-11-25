/**
 * L3-a 端到端骨架 · 装载器灌镜像 → 联锁 → 核心启动跑最小加法程序
 *
 * 叠加路线前半段验证（不接 engine_ctrl / 命令块握手；引擎空转不驱动）：
 *  1. image_loader 经 dbg 写口把结构化镜像（程序段 0000、数据段 3000）灌入主存；
 *  2. 联锁：loader_done=1 且 loader_err=0 才允许启动核心；entry 经面板 arr_strt 预置；
 *  3. clear PU → start pulse，核心从 entry 取指执行最小加法程序；
 *  4. 停机后 dbg 回读 3001 / 3002，期望均为 7（3 + 4）。
 *
 * 镜像由 image-pack 从 fw_l3a.103 + fw_l3a.seg 生成 case.hex（回归脚本落盘到本目录）。
 * 本用例只验证"loader 就位 + entry 装载 + 核心启动"链路；固件发命令块 / 引擎握手属 L3-b。
 */

`timescale 1ns/1ps

module tb_loader_core;

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

    // ---- 引擎旁路（空转，不驱动命令） ----
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;
    reg  [11:0] cmd_src, cmd_dst, cmd_len;
    reg         cmd_go;
    reg         ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  eng_state;
    wire [11:0] remain;

    // ---- 调试口（写口由 loader 直连；读口由 tb 回读驱动） ----
    wire        dbg_wr_en;
    wire [11:0] dbg_wr_addr;
    wire [30:0] dbg_wr_data;
    reg  [11:0] dbg_rd_addr;
    wire [30:0] dbg_rd_data;

    // ---- 装载器 ----
    wire        loader_wr_en;
    wire [11:0] loader_wr_addr;
    wire [30:0] loader_wr_data;
    wire        loader_done, loader_err;
    wire [3:0]  loader_err_code;
    wire [11:0] loader_entry;

    integer pass, fail;
    reg [30:0] r3001, r3002;

    // ---- 时钟 ----
    initial clk = 1'b0;
    always #1 clk = ~clk;

    // ---- DUT：核心 ----
    core_top u_core (
        .clk                     ( clk                     ),
        .resetn                  ( resetn                  ),
        .dev_input_rdy           ( dev_input_rdy           ),
        .dev_input_val           ( dev_input_val           ),
        .dev_output_rdy          ( dev_output_rdy          ),
        .dev_output_ack          ( dev_output_ack         ),
        .dev_input_data          ( dev_input_data          ),
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
        .pnl_output_dec          ( pnl_output_dec         ),
        .pnl_continuous_input    ( pnl_continuous_input    ),
        .pnl_stop_after_output   ( pnl_stop_after_output ),
        .pnl_stop_at_cmp         ( pnl_stop_at_cmp       ),
        .pnl_cmp_with_strt       ( pnl_cmp_with_strt      ),
        .pnl_do_arr_c            ( pnl_do_arr_c           ),
        .pnl_arr_reg_c_value     ( pnl_arr_reg_c_value    ),
        .pnl_do_arr_strt         ( pnl_do_arr_strt        ),
        .pnl_arr_strt_value      ( pnl_arr_strt_value     ),
        .pnl_do_arr_sel          ( pnl_do_arr_sel         ),
        .pnl_arr_sel_value       ( pnl_arr_sel_value      ),
        .pnl_arr_cmp_value       ( pnl_arr_cmp_value      ),
        .pnl_input_active        ( pnl_input_active       ),
        .pnl_output_active       ( pnl_output_active      ),
        .pnl_op_code             ( pnl_op_code             ),
        .pnl_strt_value          ( pnl_strt_value         ),
        .pnl_sel_value           ( pnl_sel_value          ),
        .pnl_reg_c_value         ( pnl_reg_c_value        ),
        .pnl_pu_state            ( pnl_pu_state           ),
        .eng_rd_req              ( eng_rd_req             ),
        .eng_rd_addr             ( eng_rd_addr            ),
        .eng_rd_data             ( eng_rd_data            ),
        .eng_wr_req              ( eng_wr_req             ),
        .eng_wr_addr             ( eng_wr_addr            ),
        .eng_wr_data             ( eng_wr_data            ),
        .dbg_wr_en               ( loader_wr_en          ),
        .dbg_wr_addr             ( loader_wr_addr         ),
        .dbg_wr_data             ( loader_wr_data        ),
        .dbg_rd_addr             ( dbg_rd_addr            ),
        .dbg_rd_data             ( dbg_rd_data            )
    );

    // ---- 引擎（空转：命令恒零，不参与 L3-a 判据） ----
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
        .state          ( eng_state    ),
        .remain         ( remain       )
    );

    // ---- 装载器：写口复用仿真 dbg 通路 ----
    image_loader #(.WORDS(2048)) u_loader (
        .clk            ( clk            ),
        .resetn         ( resetn          ),
        .loader_wr_en   ( loader_wr_en  ),
        .loader_wr_addr ( loader_wr_addr ),
        .loader_wr_data ( loader_wr_data ),
        .loader_done    ( loader_done   ),
        .loader_err     ( loader_err    ),
        .loader_err_code( loader_err_code ),
        .loader_entry   ( loader_entry   )
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

    // ---- 备查波形 ----
    initial begin
        $dumpfile("tb_loader_core.vcd");
        $dumpvars(0, tb_loader_core);
    end

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
        cmd_src = 0; cmd_dst = 0; cmd_len = 0; cmd_go = 0;
        ack_done = 0; ack_err = 0;
        dbg_rd_addr = 0;
        pass = 0; fail = 0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // 1) 等待装载完成或报错（联锁门控：未完成不启动核心）
        wait (loader_done || loader_err);
        if (loader_err) begin
            $display("FAIL loader error code=%0d", loader_err_code);
            fail = fail + 1;
        end else begin
            $display("loader DONE, entry=%04o", loader_entry);
            if (loader_entry === 12'o0000) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL entry expect 0000 got %04o", loader_entry); end
        end

        // 2) 预置入口（面板 arr_strt）→ clear PU → start
        @(negedge clk);
        pnl_arr_strt_value = loader_entry;
        pnl_do_arr_strt    = 1'b1;
        #4;
        pnl_do_arr_strt    = 1'b0;

        @(negedge clk);
        pnl_clear_pu = 1'b1;
        #4;
        pnl_clear_pu = 1'b0;

        @(negedge clk);
        pnl_start_pulse = 1'b1;
        #4;
        pnl_start_pulse = 1'b0;

        // 3) 等待停机
        wait (machine_stop);
        $display("machine stopped, strt=%o op=%o c=%h", pnl_strt_value, pnl_op_code, pnl_reg_c_value);

        // 4) 回读结果
        dbg_rd_addr = 12'o3001;
        @(negedge clk); @(negedge clk);
        r3001 = dbg_rd_data;
        dbg_rd_addr = 12'o3002;
        @(negedge clk); @(negedge clk);
        r3002 = dbg_rd_data;

        $display("mem[3001]=%h  mem[3002]=%h  expect 7", r3001, r3002);
        if (r3001 === 31'd7) pass = pass + 1; else begin fail = fail + 1; $display("FAIL 3001 expect 7 got %h", r3001); end
        if (r3002 === 31'd7) pass = pass + 1; else begin fail = fail + 1; $display("FAIL 3002 expect 7 got %h", r3002); end

        $display("LOADER-CORE PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("LOADER-CORE E2E PASS");
        else           $display("LOADER-CORE E2E FAIL");

        #10 $finish;
    end

    // ---- 全局超时兜底 ----
    initial begin
        #200000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
