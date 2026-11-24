/**
 * ЗУ · 行为数组存储模型（独立 iverilog 闭环副本）
 *
 * 端口与时序对齐既有 S011 堆叠 memory.v：读/写各一拍，reply 脉冲沿用
 * read_finish_r / write_finish_r 语义。内部改为扁平 reg 数组，使引擎旁路
 * 与调试读写可直连同一存储；S011 原始实现备查见 memory_s011.v.orig。
 *
 * 本文件是 work/ip_core 内的工程副本，既有 verify/hardware 仓库原位未改。
 */

module memory #(
    parameter integer WORDS = 2048
)(
    input         clk,
    input         resetn,

    input         mem_read_from_pu,
    input         mem_read_from_pnl,
    input         mem_write_from_io,
    input         mem_write_from_pnl,
    output        mem_read_reply_to_pu,
    output        mem_read_reply_to_ac,
    output        mem_write_reply_to_op,
    output        mem_write_reply_to_io,
    output        mem_reply_to_io,

    input  [11:0] sel_value_from_sel,

    input         write_sign_from_ac,
    input  [29:0] write_data_from_au,
    output        read_sign_to_ac,
    output [29:0] read_data_to_au,

    // ---- 引擎读写旁路（2b 串联用） ----
    input         eng_rd_req,
    input  [11:0] eng_rd_addr,
    output [30:0] eng_rd_data,
    input         eng_wr_req,
    input  [11:0] eng_wr_addr,
    input  [30:0] eng_wr_data,

    // ---- 装配模块命令块旁路（命令字 / 状态镜像） ----
    input         ctrl_rd_req,
    input  [11:0] ctrl_rd_addr,
    output [30:0] ctrl_rd_data,
    input         ctrl_wr_req,
    input  [11:0] ctrl_wr_addr,
    input  [30:0] ctrl_wr_data,

    // ---- 调试读写口（testbench 预填 / 直读校验） ----
    input         dbg_wr_en,
    input  [11:0] dbg_wr_addr,
    input  [30:0] dbg_wr_data,
    input  [11:0] dbg_rd_addr,
    output [30:0] dbg_rd_data,

    // ---- 写口仲裁观测（CPU / 引擎子系统授权与冲突指示） ----
    output        grant_cpu,
    output        grant_eng,
    output        arb_conflict,
    // 仲裁背压回接：1 = 对应写主队列已满
    output        cpu_stall,
    output        eng_stall
);

    reg [30:0] mem [0:WORDS-1];

    wire do_mem_read  = mem_read_from_pu  || mem_read_from_pnl;
    wire do_mem_write = mem_write_from_io || mem_write_from_pnl;

    wire [11:0] addr = sel_value_from_sel;
    wire [30:0] write_data = {write_sign_from_ac, write_data_from_au};

    reg [30:0] write_data_r;
    reg [30:0] read_data_r;
    reg [11:0] addr_r;

    reg writing;
    reg reading;
    reg write_finish_r;
    reg read_finish_r;
    reg cpu_hold;

    // 写数据 / 地址锁存（do_mem_write 拍刷新；挂起期间保持旧值）
    always @(posedge clk) begin
        if (~resetn) begin
            write_data_r <= 31'b0;
            addr_r       <= 12'b0;
        end else if (do_mem_write && !cpu_hold) begin
            write_data_r <= write_data;
            addr_r       <= addr;
        end
    end

    // CPU 写挂起保持：满队拍未入队则置 hold；stall 撤销（有空位）后释放
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cpu_hold <= 1'b0;
        end else if (cpu_hold) begin
            if (!cpu_stall) cpu_hold <= 1'b0;
        end else if (do_mem_write && cpu_stall) begin
            cpu_hold <= 1'b1;
        end
    end

    // 读地址锁存（do_mem_read 拍）
    always @(posedge clk) begin
        if (do_mem_read) addr_r <= addr;
    end

    // ---- 写主收敛到仲裁器 ----
    // CPU 写主：writing 拍（请求已延迟一拍对齐数组写口径）。
    wire        cpu_wr_req  = writing;
    wire [11:0] cpu_wr_addr = addr_r;
    wire [30:0] cpu_wr_data = write_data_r;

    // 引擎子系统写主：拷贝引擎搬运 + 装配模块状态镜像。二者同拍冲突时
    // 搬运写优先（eng 在前），ctrl 幂等状态写顺延一拍，与“装载期核心停住、
    // 引擎优先占写口”的本阶段约定一致。
    // 旁路未接时端口为 z，=== 1'b1 归一化把 z/x 视为 0，避免不确定电平
    // 经组合 mux 传入仲裁器拉坏 CPU 授权。
    wire        eng_active  = (eng_wr_req  === 1'b1);
    wire        ctrl_active = (ctrl_wr_req === 1'b1);
    wire        engsys_wr_req  = eng_active | ctrl_active;
    wire [11:0] engsys_wr_addr = eng_active ? eng_wr_addr : ctrl_wr_addr;
    wire [30:0] engsys_wr_data  = eng_active ? eng_wr_data : ctrl_wr_data;

    wire        ram_wr_req;
    wire [11:0] ram_wr_addr;
    wire [30:0] ram_wr_data;

    mem_write_arbiter u_wr_arb (
        .clk          (clk),
        .resetn       (resetn),
        .cpu_wr_req   (cpu_wr_req),
        .cpu_wr_addr  (cpu_wr_addr),
        .cpu_wr_data  (cpu_wr_data),
        .eng_wr_req   (engsys_wr_req),
        .eng_wr_addr  (engsys_wr_addr),
        .eng_wr_data  (engsys_wr_data),
        .ram_wr_req   (ram_wr_req),
        .ram_wr_addr  (ram_wr_addr),
        .ram_wr_data  (ram_wr_data),
        .grant_cpu    (grant_cpu),
        .grant_eng    (grant_eng),
        .conflict     (arb_conflict),
        .cpu_full      (),
        .eng_full      (),
        .cpu_stall     (cpu_stall),
        .eng_stall     (eng_stall)
    );

    // 唯一功能写口经仲裁器落数组；dbg 调试写旁路保留（复位/预填期使用）。
    always @(posedge clk) begin
        if (ram_wr_req) mem[ram_wr_addr] <= ram_wr_data;
        if (dbg_wr_en)  mem[dbg_wr_addr] <= dbg_wr_data;
    end

    // 读：reading 拍锁存数组读出
    always @(posedge clk) begin
        if (~resetn) read_data_r <= 31'b0;
        else if (reading) read_data_r <= mem[addr_r];
    end

    always @(posedge clk) begin
        if (~resetn) reading <= 1'b0;
        else reading <= do_mem_read;
    end

    always @(posedge clk) begin
        if (~resetn) writing <= 1'b0;
        else writing <= do_mem_write || cpu_hold;
    end

    // 写 reply 跟随 CPU 授权拍：被引擎抢占挂起期间 reply 一并推迟，
    // 待 grant_cpu 真正落数组后一拍回送；上层 IO/PU 写态本就阻塞等 reply，
    // 推迟对其透明，不会提前推进导致丢字。
    always @(posedge clk) begin
        if (~resetn) begin
            write_finish_r <= 1'b0;
            read_finish_r  <= 1'b0;
        end else begin
            write_finish_r <= grant_cpu;
            read_finish_r  <= reading;
        end
    end

    // reply 信号（沿用原语义）
    assign mem_write_reply_to_io = write_finish_r;
    assign mem_write_reply_to_op = write_finish_r;
    assign mem_read_reply_to_pu  = read_finish_r;
    assign mem_read_reply_to_ac  = read_finish_r;
    assign mem_reply_to_io       = write_finish_r || read_finish_r;

    assign {read_sign_to_ac, read_data_to_au} = read_data_r;

    // 旁路 / 调试读（组合）
    assign eng_rd_data = mem[eng_rd_addr];
    assign ctrl_rd_data = mem[ctrl_rd_addr];
    assign dbg_rd_data = mem[dbg_rd_addr];

endmodule
