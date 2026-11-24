/**
 * 103 复刻 · 共享 RAM 写口公平仲裁器（时序 · 背压队列 + 轮转防饥饿）
 *
 * 两个写主：
 *   - CPU（内核数据通路，来自 memory 既有写口）
 *   - 引擎子系统（拷贝引擎搬运 + 装配模块状态镜像，在 memory/path 层合并为一路）
 *
 * 仲裁规则：
 *   - 每主一个 FIFO_DEPTH 深同步请求队列：请求拍把 addr/data 入队排队，
 *     仲裁取队头授权；队列按先进先出顺序出队，不依赖外部请求电平保持，
 *     可适配单拍请求的 FSM。
 *   - 单主队列非空：直通授权该主。
 *   - 双主同时非空：round-robin 轮转，上轮授权方本轮让位，避免一方饥饿。
 *   - 队列满时新请求不入队（背压点），full 标志引出供后续接写主侧反压；
 *     满队期间队头不被覆盖。授权唯一，RAM 单写口，不会双写。
 *   - conflict 仅作双主同时待写的观测指示。
 *
 * 时序：clk 上升沿，resetn 低有效复位。地址 12 位、数据 31 位，与既有内存口对齐。
 */

module mem_write_arbiter #(
    parameter integer FIFO_DEPTH = 4      // 必须为 2 的幂
)(
    input         clk,
    input         resetn,

    // ---- CPU 写主 ----
    input         cpu_wr_req,
    input  [11:0] cpu_wr_addr,
    input  [30:0] cpu_wr_data,

    // ---- 引擎子系统写主 ----
    input         eng_wr_req,
    input  [11:0] eng_wr_addr,
    input  [30:0] eng_wr_data,

    // ---- 到共享 RAM ----
    output        ram_wr_req,
    output [11:0] ram_wr_addr,
    output [30:0] ram_wr_data,

    // ---- 授权 / 冲突 / 背压指示 ----
    output        grant_cpu,
    output        grant_eng,
    output        conflict,
    output        cpu_full,
    output        eng_full
);

    localparam integer PW   = $clog2(FIFO_DEPTH);   // 指针位宽（不含满判定位）
    localparam integer DW   = 12 + 31;              // 队列条目位宽

    // ---- CPU 请求队列 ----
    reg [DW-1:0] cpu_q [0:FIFO_DEPTH-1];
    reg [PW:0]   cpu_wp;            // 写指针（多 1 位判 full/empty）
    reg [PW:0]   cpu_rp;            // 读指针

    // ---- 引擎子系统请求队列 ----
    reg [DW-1:0] eng_q [0:FIFO_DEPTH-1];
    reg [PW:0]   eng_wp;
    reg [PW:0]   eng_rp;

    // 轮转记录：1 = 上轮授权引擎，0 = 上轮授权 CPU（复位默认先让 CPU 一轮）
    reg          last_eng;

    // ---- 空 / 满判定 ----
    wire cpu_empty = (cpu_wp == cpu_rp);
    wire eng_empty = (eng_wp == eng_rp);
    assign cpu_full = (cpu_wp[PW] != cpu_rp[PW]) &&
                      (cpu_wp[PW-1:0] == cpu_rp[PW-1:0]);
    assign eng_full = (eng_wp[PW] != eng_rp[PW]) &&
                      (eng_wp[PW-1:0] == eng_rp[PW-1:0]);

    // ---- 队头条目 ----
    wire [11:0] cpu_head_addr = cpu_q[cpu_rp[PW-1:0]][DW-1:31];
    wire [30:0] cpu_head_data  = cpu_q[cpu_rp[PW-1:0]][30:0];
    wire [11:0] eng_head_addr = eng_q[eng_rp[PW-1:0]][DW-1:31];
    wire [30:0] eng_head_data  = eng_q[eng_rp[PW-1:0]][30:0];

    // ---- 待写（队列非空即有待写） ----
    wire cpu_pending = !cpu_empty;
    wire eng_pending = !eng_empty;

    // ---- 授权组合：双待写按 last_eng 轮转；单待写直通 ----
    // last_eng=1（上轮引擎）→ 本轮让 CPU；last_eng=0（上轮 CPU）→ 本轮让引擎。
    assign grant_cpu = cpu_pending && (!eng_pending ||  last_eng);
    assign grant_eng = eng_pending && (!cpu_pending || !last_eng);

    assign ram_wr_req  = grant_cpu | grant_eng;
    assign ram_wr_addr = grant_cpu ? cpu_head_addr : eng_head_addr;
    assign ram_wr_data = grant_cpu ? cpu_head_data : eng_head_data;

    assign conflict = cpu_pending & eng_pending;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cpu_wp    <= {PW+1{1'b0}};
            cpu_rp    <= {PW+1{1'b0}};
            eng_wp    <= {PW+1{1'b0}};
            eng_rp    <= {PW+1{1'b0}};
            last_eng  <= 1'b0;
        end else begin
            // ---- CPU 入队 / 出队 ----
            if (cpu_wr_req && !cpu_full) begin
                cpu_q[cpu_wp[PW-1:0]] <= {cpu_wr_addr, cpu_wr_data};
                cpu_wp <= cpu_wp + 1'b1;
            end
            if (grant_cpu && !cpu_empty) begin
                cpu_rp <= cpu_rp + 1'b1;
            end

            // ---- 引擎子系统入队 / 出队 ----
            if (eng_wr_req && !eng_full) begin
                eng_q[eng_wp[PW-1:0]] <= {eng_wr_addr, eng_wr_data};
                eng_wp <= eng_wp + 1'b1;
            end
            if (grant_eng && !eng_empty) begin
                eng_rp <= eng_rp + 1'b1;
            end

            // ---- 轮转记录更新 ----
            if (grant_eng)      last_eng <= 1'b1;
            else if (grant_cpu) last_eng <= 1'b0;
        end
    end

endmodule
