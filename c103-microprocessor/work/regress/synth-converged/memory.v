/**
 * 综合探针变体 · 收敛形态 memory（非交付 RTL，仅 Gowin 综合验证用）
 *
 * 基于内核 memory.v，按 4c 复核结论把主数组端口收敛到 BRAM 双口模板：
 *   - 唯一功能写口：仲裁器输出 ram_wr_req/addr/data；
 *   - 两个同步读口：CPU 主读 read_data_r、eng 旁路 eng_rd_data_r；
 *   - dbg 调试写旁路不写数组（综合期剥离，仿真预填通路另议）；
 *   - ctrl / dbg 旁路读不直读数组（消除组合读阻碍；命令块收敛路线另定）。
 *
 * 对外端口与正本一致，core_top 连线不改；本文件不进 iverilog 回归基线。
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

    // ---- 引擎读写旁路 ----
    input         eng_rd_req,
    input  [11:0] eng_rd_addr,
    output [30:0] eng_rd_data,
    input         eng_wr_req,
    input  [11:0] eng_wr_addr,
    input  [30:0] eng_wr_data,

    // ---- 装配模块命令块旁路（变体：不接主数组） ----
    input         ctrl_rd_req,
    input  [11:0] ctrl_rd_addr,
    output [30:0] ctrl_rd_data,
    input         ctrl_wr_req,
    input  [11:0] ctrl_wr_addr,
    input  [30:0] ctrl_wr_data,

    // ---- 调试读写口（变体：不接主数组） ----
    input         dbg_wr_en,
    input  [11:0] dbg_wr_addr,
    input  [30:0] dbg_wr_data,
    input  [11:0] dbg_rd_addr,
    output [30:0] dbg_rd_data,

    // ---- 写口仲裁观测 ----
    output        grant_cpu,
    output        grant_eng,
    output        arb_conflict,
    output        cpu_stall,
    output        eng_stall,

    // ---- 命令块写旁路（综合变体：命令块已剥离本地寄存器组，主存不留副本，输出归零） ----
    output        cmd_wr_en,
    output [11:0] cmd_wr_addr,
    output [30:0] cmd_wr_data
);

    reg [30:0] mem [0:WORDS-1];

    wire do_mem_read  = mem_read_from_pu  || mem_read_from_pnl;
    wire do_mem_write = mem_write_from_io || mem_write_from_pnl;

    wire [11:0] addr = sel_value_from_sel;
    wire [30:0] write_data = {write_sign_from_ac, write_data_from_au};

    reg [30:0] write_data_r;
    reg [30:0] read_data_r;
    reg [11:0] addr_wr_r;
    reg [11:0] addr_rd_r;

    reg [30:0] eng_rd_data_r;

    reg writing;
    reg reading;
    reg write_finish_r;
    reg read_finish_r;
    reg cpu_hold;

    // 写数据 / 地址锁存
    always @(posedge clk) begin
        if (~resetn) begin
            write_data_r <= 31'b0;
            addr_wr_r    <= 12'b0;
        end else if (do_mem_write && !cpu_hold) begin
            write_data_r <= write_data;
            addr_wr_r    <= addr;
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cpu_hold <= 1'b0;
        end else if (cpu_hold) begin
            if (!cpu_stall) cpu_hold <= 1'b0;
        end else if (do_mem_write && cpu_stall) begin
            cpu_hold <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (do_mem_read) addr_rd_r <= addr;
    end

    wire        cpu_wr_req  = writing;
    wire [11:0] cpu_wr_addr = addr_wr_r;
    wire [30:0] cpu_wr_data = write_data_r;

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

    // 唯一功能写口落数组；dbg 调试写旁路在综合变体中剥离。
    always @(posedge clk) begin
        if (ram_wr_req) mem[ram_wr_addr] <= ram_wr_data;
    end

    // CPU 同步读
    always @(posedge clk) begin
        if (~resetn) read_data_r <= 31'b0;
        else if (reading) read_data_r <= mem[addr_rd_r];
    end

    always @(posedge clk) begin
        if (~resetn) reading <= 1'b0;
        else reading <= do_mem_read;
    end

    always @(posedge clk) begin
        if (~resetn) writing <= 1'b0;
        else writing <= do_mem_write || cpu_hold;
    end

    always @(posedge clk) begin
        if (~resetn) begin
            write_finish_r <= 1'b0;
            read_finish_r  <= 1'b0;
        end else begin
            write_finish_r <= grant_cpu;
            read_finish_r  <= reading;
        end
    end

    assign mem_write_reply_to_io = write_finish_r;
    assign mem_write_reply_to_op = write_finish_r;
    assign mem_read_reply_to_pu  = read_finish_r;
    assign mem_read_reply_to_ac  = read_finish_r;
    assign mem_reply_to_io       = write_finish_r || read_finish_r;

    assign {read_sign_to_ac, read_data_to_au} = read_data_r;

    // eng 旁路同步读
    always @(posedge clk) begin
        if (~resetn) eng_rd_data_r <= 31'b0;
        else         eng_rd_data_r <= mem[eng_rd_addr];
    end

    assign eng_rd_data  = eng_rd_data_r;

    // 变体：ctrl / dbg 旁路读不接主数组，输出归零（命令块收敛路线另定）。
    assign ctrl_rd_data = 31'b0;
    assign dbg_rd_data  = 31'b0;

    // 变体：命令块写旁路不接主数组，输出归零。
    assign cmd_wr_en   = 1'b0;
    assign cmd_wr_addr = 12'b0;
    assign cmd_wr_data = 31'b0;

endmodule
