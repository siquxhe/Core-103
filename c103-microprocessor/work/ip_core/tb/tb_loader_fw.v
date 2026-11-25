/**
 * L3-b 端到端 · 装载器就位 + 固件主动发命令块 + 引擎搬运握手闭环
 *
 * 叠加路线后半段（在 L3-a loader 联锁基础上接回 engine_ctrl / copy_engine）：
 *  1. image_loader 经 dbg 写口灌入镜像：固件程序段 0000、常量段 2000、源数据段 1000；
 *  2. 联锁：loader_done=1 且 err=0 才启动核心，entry 经面板 arr_strt 预置；
 *  3. 固件经 05 传送写命令块 SRC/DST/LEN/GO(2400..2403)，ctrl 装配并启动引擎；
 *  4. 固件轮询 DONE(2405) 镜像，完成后写 ACK(2407)，ctrl 回 ack_done，引擎回 IDLE；
 *  5. 判据：目的区 3000..3002 = 3/4/5；引擎回 IDLE；ACK/DONE 镜像自清；核心停机。
 *
 * 镜像由 image-pack 从 fw_l3b.103 + fw_l3b.seg 生成 case.hex（回归脚本落盘到本目录）。
 */

`timescale 1ns/1ps

module tb_loader_fw;

    reg clk;
    reg resetn;
    reg core_resetn;

    // ---- dev 握手 ----
    wire        dev_input_rdy;
    reg         dev_input_val;
    wire        dev_output_rdy;
    reg         dev_output_ack;
    reg  [4:0]  dev_input_data;
    wire [4:0]  dev_output_data;

    // ---- 面板脉冲 / 电平 ----
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

    // ---- 引擎 / ctrl 旁路 ----
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire        eng_rd_req, eng_wr_req;
    wire [30:0] eng_rd_data, eng_wr_data;

    wire        ctrl_rd_req;
    wire [11:0] ctrl_rd_addr;
    wire [30:0] ctrl_rd_data;
    wire        ctrl_wr_req;
    wire [11:0] ctrl_wr_addr;
    wire [30:0] ctrl_wr_data;

    // ---- 命令块写旁路（memory → engine_ctrl 本地寄存器） ----
    wire        cmd_wr_en;
    wire [11:0] cmd_wr_addr;
    wire [30:0] cmd_wr_data;

    // ---- 调试口 ----
    wire        dbg_wr_en;
    wire [11:0] dbg_wr_addr;
    wire [30:0] dbg_wr_data;
    reg  [11:0] dbg_rd_addr;
    wire [30:0] dbg_rd_data;

    // ---- 引擎命令 / 握手 ----
    wire [11:0] cmd_src, cmd_dst, cmd_len;
    wire        cmd_go, ack_done, ack_err;
    wire        busy, done, err;
    wire [1:0]  err_code;
    wire [2:0]  eng_state;
    wire [11:0] remain;

    // ---- 装载器 ----
    wire        loader_wr_en;
    wire [11:0] loader_wr_addr;
    wire [30:0] loader_wr_data;
    wire        loader_done, loader_err;
    wire [3:0]  loader_err_code;
    wire [11:0] loader_entry;

    // ---- 命令块地址（八进制） ----
    localparam [11:0] A_SRC  = 12'o2400;
    localparam [11:0] A_DST  = 12'o2401;
    localparam [11:0] A_LEN  = 12'o2402;
    localparam [11:0] A_GO   = 12'o2403;
    localparam [11:0] A_BUSY  = 12'o2404;
    localparam [11:0] A_DONE = 12'o2405;
    localparam [11:0] A_ERR  = 12'o2406;
    localparam [11:0] A_ACK  = 12'o2407;

    localparam [11:0] D_DST = 12'o3000;

    integer pass, fail;
    reg [30:0] r0, r1, r2, tmp;
    integer guard;
    reg        round_ok;

    initial clk = 1'b0;
    always #1 clk = ~clk;

    // ---- DUT：核心 ----
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
        .dbg_rd_addr(dbg_rd_addr), .dbg_rd_data(dbg_rd_data),
        .cmd_wr_en(cmd_wr_en), .cmd_wr_addr(cmd_wr_addr), .cmd_wr_data(cmd_wr_data)
    );

    // ---- DUT：引擎 ----
    copy_engine #(.MEM_SIZE(2048)) u_eng (
        .clk(clk), .resetn(resetn),
        .cmd_src(cmd_src), .cmd_dst(cmd_dst), .cmd_len(cmd_len), .cmd_go(cmd_go),
        .rd_addr(eng_rd_addr), .rd_req(eng_rd_req), .rd_data(eng_rd_data),
        .wr_addr(eng_wr_addr), .wr_data(eng_wr_data), .wr_req(eng_wr_req),
        .ack_done(ack_done), .ack_err(ack_err),
        .busy(busy), .done(done), .err(err), .err_code(err_code),
        .state(eng_state), .remain(remain)
    );

    // ---- DUT：装配 ctrl ----
    engine_ctrl #(
        .ADDR_SRC(A_SRC), .ADDR_DST(A_DST), .ADDR_LEN(A_LEN), .ADDR_GO(A_GO),
        .ADDR_BUSY(A_BUSY), .ADDR_DONE(A_DONE), .ADDR_ERR(A_ERR), .ADDR_ACK(A_ACK)
    ) u_ctrl (
        .clk(clk), .resetn(resetn),
        .ctrl_rd_req(ctrl_rd_req), .ctrl_rd_addr(ctrl_rd_addr), .ctrl_rd_data(ctrl_rd_data),
        .ctrl_wr_req(ctrl_wr_req), .ctrl_wr_addr(ctrl_wr_addr), .ctrl_wr_data(ctrl_wr_data),
        .local_wr_en(cmd_wr_en), .local_wr_addr(cmd_wr_addr), .local_wr_data(cmd_wr_data),
        .cmd_src(cmd_src), .cmd_dst(cmd_dst), .cmd_len(cmd_len), .cmd_go(cmd_go),
        .ack_done(ack_done), .ack_err(ack_err),
        .busy(busy), .done(done), .err(err), .err_code(err_code)
    );

    // ---- 装载器：写口复用仿真 dbg 通路 ----
    image_loader #(.WORDS(2048)) u_loader (
        .clk(clk), .resetn(resetn),
        .loader_wr_en(loader_wr_en), .loader_wr_addr(loader_wr_addr), .loader_wr_data(loader_wr_data),
        .loader_done(loader_done), .loader_err(loader_err), .loader_err_code(loader_err_code),
        .loader_entry(loader_entry)
    );

    assign dbg_wr_en   = loader_wr_en;
    assign dbg_wr_addr = loader_wr_addr;
    assign dbg_wr_data = loader_wr_data;

    // ---- 停机判据 ----
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

    initial begin
        $dumpfile("tb_loader_fw.vcd");
        $dumpvars(0, tb_loader_fw);
    end

    initial begin
        resetn = 1'b0; core_resetn = 1'b0;
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
        dbg_rd_addr = 0;
        pass = 0; fail = 0;

        #8 resetn = 1'b1;
        @(negedge clk);

        // 1) 等待装载完成或报错
        wait (loader_done || loader_err);
        if (loader_err) begin
            $display("FAIL loader error code=%0d", loader_err_code);
            fail = fail + 1;
        end else begin
            $display("loader DONE, entry=%04o", loader_entry);
            if (loader_entry === 12'o0000) pass = pass + 1;
            else begin fail = fail + 1; $display("FAIL entry expect 0000 got %04o", loader_entry); end
        end

        // 2) 预置入口 → clear PU → start（只清核心 PU/IO，不复位引擎/ctrl）
        @(negedge clk);
        core_resetn = 1'b0; #6; core_resetn = 1'b1;
        @(negedge clk);
        pnl_arr_strt_value = loader_entry;
        pnl_do_arr_strt    = 1'b1; #4; pnl_do_arr_strt = 1'b0;
        @(negedge clk);
        pnl_clear_pu = 1'b1; #4; pnl_clear_pu = 1'b0;
        @(negedge clk);
        pnl_start_pulse = 1'b1; #4; pnl_start_pulse = 1'b0;

        // 3) 等待核心停机（固件发命令块 → 轮询 → ACK → 停机）
        wait (machine_stop);
        $display("machine stopped, strt=%o op=%o c=%h", pnl_strt_value, pnl_op_code, pnl_reg_c_value);

        // 4) 目的区逐字比对 3/4/5
        dbg_read(D_DST+12'd0, r0);
        dbg_read(D_DST+12'd1, r1);
        dbg_read(D_DST+12'd2, r2);
        $display("mem[3000]=%h mem[3001]=%h mem[3002]=%h expect 3/4/5", r0, r1, r2);
        if (r0 === 31'd3) pass = pass + 1; else begin fail = fail + 1; $display("FAIL 3000 expect 3 got %h", r0); end
        if (r1 === 31'd4) pass = pass + 1; else begin fail = fail + 1; $display("FAIL 3001 expect 4 got %h", r1); end
        if (r2 === 31'd5) pass = pass + 1; else begin fail = fail + 1; $display("FAIL 3002 expect 5 got %h", r2); end

        // 5) 握手闭环：引擎回 IDLE，ACK/DONE 镜像自清
        if (eng_state === 3'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL engine not IDLE state=%0d", eng_state); end
        dbg_read(A_ACK, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL ACK not cleared=%h", tmp); end
        dbg_read(A_DONE, tmp);
        if (tmp === 31'd0) pass = pass + 1; else begin fail = fail + 1; $display("FAIL DONE residual=%h", tmp); end

        $display("LOADER-FW PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) $display("LOADER-FW E2E PASS");
        else           $display("LOADER-FW E2E FAIL");

        #10 $finish;
    end

    initial begin
        #500000;
        $display("FAIL global timeout");
        $finish;
    end

endmodule
