/**
 * 103 复刻 · 整链路综合装配 wrapper（L4 量产综合形态复核用，非交付 RTL）
 *
 * 装配对象（同一网表）：
 *   - core_top：内核 arith/operator/pulse/select/start/io 通路 + 内部 memory/仲裁器；
 *   - copy_engine：搬运 FSM（含 ST_RD_WAIT 同步读等待拍）；
 *   - engine_ctrl：命令块 FSM + 本地 cmd_q 寄存器组 + 状态镜像回写。
 *
 * 连线口径（对齐 tb_engine_ctrl 仿真装配关系）：
 *   - eng 旁路：copy_engine 读/写 ↔ core_top 内部 memory；
 *   - ctrl 旁路：engine_ctrl 命令块读写 ↔ core_top 内部 memory；
 *   - 命令块本地寄存器：core_top.cmd_wr_* → engine_ctrl.local_wr_*；
 *   - ctrl ↔ engine 命令/状态：cmd_src/dst/len/go、ack_done/ack_err、busy/done/err/err_code；
 *   - dbg 调试口量产形态 tie 0，不连内部逻辑；
 *   - 内核 dev/pnl 面板输入在综合统计顶层 tie 0（无激励保活，不参与资源评估）。
 *
 * 边界说明：
 *   - image_loader 路线 A 模型含 $readmemh initial 块，不可综合，不入本网表；
 *     量产装载走路线 B（SPI NOR 字流），属上板改造，见 4h §3 / §7。
 *   - copy_engine.wr_stall 背压：core_top 未把仲裁器 eng_stall 直通引出到顶层，
 *     本顶层暂 tie 0；整链路背压闭环需后续在 core_top 直通 eng_stall 端口。
 *   - 本顶层仅用于 Gowin 综合资源 / 时序估算；行为仿真回归仍走正本 memory.v + 既有 tb。
 */

`timescale 1ns / 1ps

module fullchain_wrapper (
    input  clk,
    input  resetn,

    // ---- 引擎 / 装配状态观测 ----
    output        busy,
    output        done,
    output        err,
    output [1:0]  err_code,
    output [2:0]  eng_state,
    output [11:0] remain,

    // ---- 仲裁观测 ----
    output        grant_cpu,
    output        grant_eng,
    output        arb_conflict
);

    // ---- eng 旁路（core_top ↔ copy_engine） ----
    wire         eng_rd_req;
    wire [11:0]  eng_rd_addr;
    wire [30:0]  eng_rd_data;
    wire         eng_wr_req;
    wire [11:0]  eng_wr_addr;
    wire [30:0]  eng_wr_data;

    // ---- ctrl 命令块旁路（core_top ↔ engine_ctrl） ----
    wire         ctrl_rd_req;
    wire [11:0]  ctrl_rd_addr;
    wire [30:0]  ctrl_rd_data;
    wire         ctrl_wr_req;
    wire [11:0]  ctrl_wr_addr;
    wire [30:0]  ctrl_wr_data;

    // ---- 命令块本地寄存器旁路（core_top → engine_ctrl） ----
    wire         cmd_wr_en;
    wire [11:0]  cmd_wr_addr;
    wire [30:0]  cmd_wr_data;

    // ---- ctrl ↔ engine 命令 / 状态 ----
    wire [11:0]  cmd_src, cmd_dst, cmd_len;
    wire         cmd_go, ack_done, ack_err;

    // ---- 核心（含共享 RAM + 写仲裁器） ----
    core_top u_core (
        .clk                     ( clk                     ),
        .resetn                  ( resetn                  ),

        // dev 握手：综合顶层无激励，tie 0
        .dev_input_rdy           (                         ),
        .dev_input_val           ( 1'b0                    ),
        .dev_output_rdy          (                         ),
        .dev_output_ack          ( 1'b0                    ),
        .dev_input_data          ( 5'd0                    ),
        .dev_output_data         (                         ),

        // 面板脉冲 / 电平：tie 0
        .pnl_start_pulse         ( 1'b0                    ),
        .pnl_clear_pu            ( 1'b0                    ),
        .pnl_automatic           ( 1'b0                    ),
        .pnl_mem_read            ( 1'b0                    ),
        .pnl_mem_write           ( 1'b0                    ),
        .pnl_start_input         ( 1'b0                    ),
        .pnl_stop_input          ( 1'b0                    ),
        .pnl_start_output        ( 1'b0                    ),
        .pnl_stop_output         ( 1'b0                    ),
        .pnl_input_dec           ( 1'b0                    ),
        .pnl_output_dec          ( 1'b0                    ),
        .pnl_continuous_input     ( 1'b0                    ),
        .pnl_stop_after_output   ( 1'b0                    ),
        .pnl_stop_at_cmp         ( 1'b0                    ),
        .pnl_cmp_with_strt       ( 1'b0                    ),
        .pnl_do_arr_c            ( 1'b0                    ),
        .pnl_arr_reg_c_value     ( 31'd0                   ),
        .pnl_do_arr_strt         ( 1'b0                    ),
        .pnl_arr_strt_value      ( 12'd0                   ),
        .pnl_do_arr_sel          ( 1'b0                    ),
        .pnl_arr_sel_value       ( 12'd0                   ),
        .pnl_arr_cmp_value       ( 12'd0                   ),
        .pnl_input_active        (                         ),
        .pnl_output_active       (                         ),
        .pnl_op_code             (                         ),
        .pnl_strt_value          (                         ),
        .pnl_sel_value           (                         ),
        .pnl_reg_c_value         (                         ),
        .pnl_pu_state            (                         ),

        // eng 旁路
        .eng_rd_req              ( eng_rd_req              ),
        .eng_rd_addr             ( eng_rd_addr             ),
        .eng_rd_data             ( eng_rd_data             ),
        .eng_wr_req              ( eng_wr_req              ),
        .eng_wr_addr             ( eng_wr_addr             ),
        .eng_wr_data             ( eng_wr_data             ),

        // ctrl 旁路
        .ctrl_rd_req             ( ctrl_rd_req             ),
        .ctrl_rd_addr            ( ctrl_rd_addr           ),
        .ctrl_rd_data            ( ctrl_rd_data           ),
        .ctrl_wr_req             ( ctrl_wr_req            ),
        .ctrl_wr_addr            ( ctrl_wr_addr          ),
        .ctrl_wr_data            ( ctrl_wr_data           ),

        // dbg 调试口：量产形态 tie 0
        .dbg_wr_en               ( 1'b0                    ),
        .dbg_wr_addr             ( 12'd0                   ),
        .dbg_wr_data             ( 31'd0                   ),
        .dbg_rd_addr             ( 12'd0                   ),
        .dbg_rd_data             (                         ),

        // 仲裁观测
        .grant_cpu               ( grant_cpu              ),
        .grant_eng               ( grant_eng              ),
        .arb_conflict            ( arb_conflict            ),

        // 命令块写旁路
        .cmd_wr_en               ( cmd_wr_en               ),
        .cmd_wr_addr             ( cmd_wr_addr             ),
        .cmd_wr_data             ( cmd_wr_data            )
    );

    // ---- 拷贝引擎 ----
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
        .wr_stall       ( 1'b0         ),  // core_top 未引出 eng_stall，暂 tie 0
        .ack_done       ( ack_done     ),
        .ack_err        ( ack_err      ),
        .busy           ( busy         ),
        .done           ( done          ),
        .err            ( err          ),
        .err_code       ( err_code     ),
        .state          ( eng_state    ),
        .remain         ( remain       )
    );

    // ---- 命令块装配模块 ----
    engine_ctrl u_ctrl (
        .clk            ( clk         ),
        .resetn         ( resetn       ),
        .ctrl_rd_req    ( ctrl_rd_req  ),
        .ctrl_rd_addr   ( ctrl_rd_addr ),
        .ctrl_rd_data   ( ctrl_rd_data ),
        .ctrl_wr_req    ( ctrl_wr_req  ),
        .ctrl_wr_addr   ( ctrl_wr_addr),
        .ctrl_wr_data   ( ctrl_wr_data ),
        .local_wr_en    ( cmd_wr_en    ),
        .local_wr_addr  ( cmd_wr_addr  ),
        .local_wr_data  ( cmd_wr_data  ),
        .cmd_src        ( cmd_src      ),
        .cmd_dst        ( cmd_dst      ),
        .cmd_len        ( cmd_len      ),
        .cmd_go         ( cmd_go       ),
        .ack_done       ( ack_done     ),
        .ack_err        ( ack_err       ),
        .busy           ( busy         ),
        .done           ( done         ),
        .err            ( err          ),
        .err_code       ( err_code     )
    );

endmodule
