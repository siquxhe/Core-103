/**
 * 103 复刻 · 核心端到端 testbench（独立 iverilog 闭环）
 *
 * 复刻既有 Verilator main.cpp / task.cpp 的驱动模型：
 *  - clk 周期 2（#1 翻转），dev_clk 周期 10（#5 翻转），复位 time 2..8 拉低；
 *  - 解析 test/task.seq，逐条驱动面板按钮脉冲与开关电平；
 *  - dev 输入/输出握手由 sim_input / sim_output 模型自主完成；
 *  - 复刻 sim_top 的停机判据（PU 状态静止 + 无 IO 活动）。
 *
 * 本 testbench 先验证核心在 iverilog 下可直接执行既有冻结程序；
 * 引擎搬运串联在通路闭环（engine_mem_path）稳定后接入。
 */

`timescale 1ns/1ps

module tb_core_eb;

    // task 类型编码（对齐 verify-verilator/src_cc/task.h）
    localparam IDLE          = 0;
    localparam ARR_REG_C     = 1;
    localparam ARR_STRT      = 2;
    localparam ARR_SEL       = 3;
    localparam ARR_CMP       = 4;
    localparam CLEAR_STRT    = 5;
    localparam START_PULSE   = 6;
    localparam CLEAR_PULSE   = 7;
    localparam MEM_READ      = 8;
    localparam MEM_WRITE     = 9;
    localparam START_INPUT   = 10;
    localparam STOP_INPUT    = 11;
    localparam START_OUTPUT  = 12;
    localparam STOP_OUTPUT   = 13;
    localparam SET_IO_SW     = 14;
    localparam SET_MAIN_SW   = 15;

    localparam MAX_TASKS = 16;

    // ---- 时钟 / 复位 ----
    reg clk;
    reg dev_clk;
    reg resetn;

    // ---- 面板按钮 ----
    reg btn_start_pulse;
    reg btn_clear_pu;
    reg btn_mem_read;
    reg btn_mem_write;
    reg btn_start_input;
    reg btn_stop_input;
    reg btn_start_output;
    reg btn_stop_output;
    reg btn_do_arr_c;
    reg btn_do_arr_strt;
    reg btn_do_arr_sel;

    // ---- 面板开关 ----
    reg sw_input_dec;
    reg sw_output_dec;
    reg sw_continuous_input;
    reg sw_stop_after_output;
    reg sw_automatic;
    reg sw_stop_at_cmp;
    reg sw_cmp_with_strt;
    reg sw_allow_arr;
    reg [30:0] sw_arr_reg_c_value;
    reg [11:0] sw_arr_strt_value;
    reg [11:0] sw_arr_sel_value;
    reg [11:0] sw_arr_cmp_value;

    // ---- dev 握手连线 ----
    wire        dev_input_rdy;
    wire        dev_input_val;
    wire [4:0]  dev_input_data;
    wire        dev_output_rdy;
    wire        dev_output_ack;
    wire [4:0]  dev_output_data;

    // ---- 核心状态观测 ----
    wire [2:0]  pnl_pu_state;
    wire        pnl_input_active;
    wire        pnl_output_active;

    // ---- 被测顶层 ----
    hardware_top u_hw (
        .clk                     ( clk                 ),
        .resetn                  ( resetn              ),
        .dev_input_rdy           ( dev_input_rdy       ),
        .dev_input_val           ( dev_input_val       ),
        .dev_output_rdy          ( dev_output_rdy      ),
        .dev_output_ack          ( dev_output_ack      ),
        .dev_input_data          ( dev_input_data      ),
        .dev_output_data         ( dev_output_data     ),
        .btn_start_pulse         ( btn_start_pulse     ),
        .btn_clear_pu            ( btn_clear_pu        ),
        .btn_mem_read            ( btn_mem_read         ),
        .btn_mem_write           ( btn_mem_write       ),
        .btn_start_input         ( btn_start_input     ),
        .btn_stop_input          ( btn_stop_input      ),
        .btn_start_output        ( btn_start_output    ),
        .btn_stop_output         ( btn_stop_output     ),
        .sw_input_dec            ( sw_input_dec        ),
        .sw_output_dec           ( sw_output_dec      ),
        .sw_continuous_input     ( sw_continuous_input ),
        .sw_stop_after_output    ( sw_stop_after_output),
        .sw_automatic            ( sw_automatic        ),
        .sw_stop_at_cmp          ( sw_stop_at_cmp     ),
        .sw_cmp_with_strt        ( sw_cmp_with_strt    ),
        .sw_allow_arr            ( sw_allow_arr        ),
        .btn_do_arr_c            ( btn_do_arr_c       ),
        .btn_do_arr_strt         ( btn_do_arr_strt     ),
        .btn_do_arr_sel          ( btn_do_arr_sel     ),
        .pnl_pu_state            ( pnl_pu_state       ),
        .pnl_input_active        ( pnl_input_active    ),
        .pnl_output_active      ( pnl_output_active    )
    );

    sim_input u_sim_input (
        .clk        ( dev_clk       ),
        .resetn     ( resetn        ),
        .input_rdy  ( dev_input_rdy ),
        .input_val  ( dev_input_val),
        .input_data ( dev_input_data)
    );

    sim_output u_sim_output (
        .clk          ( dev_clk        ),
        .resetn       ( resetn         ),
        .output_rdy   ( dev_output_rdy ),
        .output_data  ( dev_output_data),
        .output_ack   ( dev_output_ack )
    );

    // ---- 时钟生成 ----
    initial clk = 1'b0;
    always #1 clk = ~clk;

    initial dev_clk = 1'b0;
    always #5 dev_clk = ~dev_clk;

    // ---- 停机判据（复刻 sim_top stop_counter） ----
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

    // ---- task 序列存储 ----
    integer t_type [0:MAX_TASKS-1];
    integer t_dur  [0:MAX_TASKS-1];
    integer t_wait [0:MAX_TASKS-1];
    integer t_d0   [0:MAX_TASKS-1];
    integer t_d1   [0:MAX_TASKS-1];
    integer t_d2   [0:MAX_TASKS-1];
    integer t_d3   [0:MAX_TASKS-1];
    integer task_count;

    integer cur_idx;
    integer task_start_time;
    integer t_time;

    integer fp;
    reg [8*20-1:0] name;
    reg [8*80-1:0] line;
    integer d0, d1, d2, d3, dur, wait_stop;
    integer i, res;

    // ---- 预读 task.seq ----
    initial begin
        btn_start_pulse = 0; btn_clear_pu = 0;
        btn_mem_read = 0;    btn_mem_write = 0;
        btn_start_input = 0; btn_stop_input = 0;
        btn_start_output = 0; btn_stop_output = 0;
        btn_do_arr_c = 0;   btn_do_arr_strt = 0; btn_do_arr_sel = 0;
        sw_input_dec = 0; sw_output_dec = 0;
        sw_continuous_input = 0; sw_stop_after_output = 0;
        sw_automatic = 0; sw_stop_at_cmp = 0; sw_cmp_with_strt = 0;
        sw_allow_arr = 0;
        sw_arr_reg_c_value = 0; sw_arr_strt_value = 0;
        sw_arr_sel_value = 0;  sw_arr_cmp_value = 0;

        task_count = 0;
        cur_idx = -1;
        task_start_time = 0;

        fp = $fopen("test/task.seq", "r");
        if (fp == 0) begin
            $display("FAIL cannot open test/task.seq");
            $finish;
        end

        while (task_count < MAX_TASKS && !$feof(fp)) begin
            res = $fgets(line, fp);
            if (res != 0) begin
                res = $sscanf(line, "%s", name);
                if (res == 1) begin
                    d0 = 0; d1 = 0; d2 = 0; d3 = 0; dur = 0; wait_stop = 0;
                    if (name == "set_io_sw") begin
                        t_type[task_count] = SET_IO_SW;
                        res = $sscanf(line, "%s%d%d%d%d%d%d", name, d0, d1, d2, d3, dur, wait_stop);
                    end else if (name == "set_main_sw") begin
                        t_type[task_count] = SET_MAIN_SW;
                        res = $sscanf(line, "%s%d%d%d%d%d", name, d0, d1, d2, dur, wait_stop);
                    end else if (name == "start_input") begin
                        t_type[task_count] = START_INPUT;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "stop_input") begin
                        t_type[task_count] = STOP_INPUT;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "start_output") begin
                        t_type[task_count] = START_OUTPUT;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "stop_output") begin
                        t_type[task_count] = STOP_OUTPUT;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "start_pulse") begin
                        t_type[task_count] = START_PULSE;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "clear_pulse") begin
                        t_type[task_count] = CLEAR_PULSE;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "clear_strt") begin
                        t_type[task_count] = CLEAR_STRT;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "mem_read") begin
                        t_type[task_count] = MEM_READ;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "mem_write") begin
                        t_type[task_count] = MEM_WRITE;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else if (name == "idle") begin
                        t_type[task_count] = IDLE;
                        res = $sscanf(line, "%s%d%d", name, dur, wait_stop);
                    end else begin
                        $display("FAIL unknown task %0s", name);
                        $finish;
                    end

                    t_d0[task_count] = d0; t_d1[task_count] = d1;
                    t_d2[task_count] = d2; t_d3[task_count] = d3;
                    t_dur[task_count] = dur;
                    t_wait[task_count] = wait_stop;
                    task_count = task_count + 1;
                end
            end
        end
        $fclose(fp);
        $display("parsed %0d tasks", task_count);
    end

    // ---- 复位 ----
    initial begin
        resetn = 1'b0;
        #8;
        resetn = 1'b1;
    end

    // ---- 调度：negedge clk 执行（复刻 main.cpp if(!clk)） ----
    integer next_idx;
    always @(negedge clk) begin
        if (!resetn) begin
            cur_idx = -1;
        end else if (cur_idx < 0) begin
            if (task_count > 0) begin
                cur_idx = 0;
                task_start_time = $time;
            end
        end else begin
            t_time = $time - task_start_time;

            // check_done
            if (t_time > t_dur[cur_idx] && (!t_wait[cur_idx] || machine_stop)) begin
                next_idx = cur_idx + 1;
                if (next_idx >= task_count) begin
                    $display("ALL TASKS DONE at time %0d", $time);
                    cur_idx = -2; // 完成标记
                end else begin
                    cur_idx = next_idx;
                    task_start_time = $time;
                end
            end
        end

        // do_task 面板驱动
        if (cur_idx >= 0) begin
            drive_task(t_type[cur_idx], t_time,
                       t_d0[cur_idx], t_d1[cur_idx], t_d2[cur_idx], t_d3[cur_idx]);
        end else begin
            release_buttons;
        end
    end

    // 面板驱动任务（复刻 task.cpp 各类型窗口）
    task drive_task;
        input integer ty;
        input integer tt;
        input integer a0;
        input integer a1;
        input integer a2;
        input integer a3;
        begin
            release_buttons;

            case (ty)
            SET_IO_SW: begin
                sw_input_dec         = a0;
                sw_output_dec        = a1;
                sw_continuous_input  = a2;
                sw_stop_after_output = a3;
            end
            SET_MAIN_SW: begin
                sw_automatic     = a0;
                sw_stop_at_cmp   = a1;
                sw_cmp_with_strt = a2;
            end
            START_INPUT:  if (tt > 1 && tt < 6) btn_start_input  = 1;
            STOP_INPUT:   if (tt > 1 && tt < 6) btn_stop_input   = 1;
            START_OUTPUT: if (tt > 1 && tt < 6) btn_start_output = 1;
            STOP_OUTPUT:  if (tt > 1 && tt < 6) btn_stop_output  = 1;
            START_PULSE:  if (tt > 1 && tt < 6) btn_start_pulse  = 1;
            CLEAR_PULSE:  if (tt > 1 && tt < 6) btn_clear_pu     = 1;
            MEM_READ:     if (tt > 1 && tt < 6) btn_mem_read     = 1;
            MEM_WRITE:    if (tt > 1 && tt < 6) btn_mem_write     = 1;
            CLEAR_STRT: begin
                sw_allow_arr = 1'b0;
                if (tt > 3 && tt < 8) btn_do_arr_strt = 1;
            end
            ARR_STRT: begin
                sw_allow_arr = 1'b1;
                sw_arr_strt_value = a0[11:0];
                if (tt > 128 && tt < 135) btn_do_arr_strt = 1;
            end
            ARR_REG_C: begin
                sw_allow_arr = 1'b1;
                sw_arr_reg_c_value = a0[30:0];
                if (tt > 128 && tt < 135) btn_do_arr_c = 1;
            end
            ARR_SEL: begin
                sw_allow_arr = 1'b1;
                sw_arr_sel_value = a0[11:0];
                if (tt > 128 && tt < 135) btn_do_arr_sel = 1;
            end
            ARR_CMP: begin
                sw_allow_arr = 1'b1;
                sw_arr_cmp_value = a0[11:0];
            end
            default: ;
            endcase
        end
    endtask

    task release_buttons;
        begin
            btn_start_pulse  = 1'b0;
            btn_clear_pu    = 1'b0;
            btn_mem_read    = 1'b0;
            btn_mem_write   = 1'b0;
            btn_start_input = 1'b0;
            btn_stop_input  = 1'b0;
            btn_start_output= 1'b0;
            btn_stop_output = 1'b0;
            btn_do_arr_c    = 1'b0;
            btn_do_arr_strt = 1'b0;
            btn_do_arr_sel  = 1'b0;
        end
    endtask

    // ---- 超时兜底 ----
    initial begin
        #5000000;
        $display("FAIL global timeout");
        $finish;
    end

    // ---- 完成后结束 ----
    always @(negedge clk) begin
        if (cur_idx == -2) begin
            #2;
            $display("RESULT: DONE");
            $finish;
        end
    end

endmodule
