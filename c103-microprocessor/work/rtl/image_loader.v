/**
 * P0-2 镜像加载器 · 路线 A 仿真行为模型
 *
 * 从文本十六进制镜像（$readmemh，每行一个 32 位字，布局见 4f §5.4）解析
 * 目录头 / 段表 / 镜像体 / 校验尾，完成魔数、段表边界、校验和复核后，先清零
 * 主存再按段经调试写口落入 memory。
 *
 * 路线 B 边界预留：本模块 FSM 状态划分（IDLE/CHECK/WIPE/LOAD/DONE/ERROR）与
 * 段表 / 校验口径两侧共用；上板时仅把内部 $readmemh 文本源替换为 SPI NOR
 * 控制器读回的字流，写主存的 dbg 口复用既有仲裁写口，解析与校验逻辑不变。
 *
 * 错误码（loader_err_code）：
 *   0  OK            1 镜像为空/过短
 *   2  魔数错        3 版本/算法不支持
 *   4  段数非法      5 入口 PC 越界
 *   6  段类型非法    7 段字数为 0
 *   8  目的越界      9 偏移越界
 *  10 校验和不符    11 镜像体字数与段表不符
 */
`timescale 1ns/1ps

module image_loader #(
    parameter integer WORDS = 2048
)(
    input  wire        clk,
    input  wire        resetn,

    /* 到 memory 调试写口（路线 A 复用 dbg 通路；路线 B 改接仲裁写口） */
    output reg         loader_wr_en,
    output reg  [11:0] loader_wr_addr,
    output reg  [30:0] loader_wr_data,

    output reg         loader_done,
    output reg         loader_err,
    output reg  [3:0]  loader_err_code,
    output reg  [11:0] loader_entry
);

    localparam [31:0] MAGIC    = 32'h103103;
    localparam integer MAX_SEG = 16;
    localparam integer MAX_WORD = 4096;

    localparam [3:0]
        S_IDLE   = 4'd0,
        S_CHECK  = 4'd1,
        S_WIPE   = 4'd2,
        S_LOAD   = 4'd3,
        S_DONE   = 4'd4,
        S_ERROR  = 4'd5;

    reg [31:0] img [0:MAX_WORD-1];
    integer    total_words;

    reg [3:0]  state;
    integer    seg_idx;
    integer    seg_k;
    integer    wipe_addr;

    /* 段表缓存（校验 + 装载复用） */
    reg  [11:0] seg_dst [0:MAX_SEG-1];
    reg  [11:0] seg_off [0:MAX_SEG-1];
    reg  [2:0]  seg_type[0:MAX_SEG-1];
    reg  [11:0] seg_len [0:MAX_SEG-1];
    integer     nseg;
    reg  [11:0] entry_pc;

    /* S_CHECK 工作变量（模块级，Verilog-2001 口径） */
    integer    v_n, v_entry, v_ver, v_algo, v_body_start, v_body_words, v_ok;
    reg [31:0]  v_a, v_b;
    reg [30:0]  v_cksum;
    integer     v_i;

    /* 文本镜像读入：$readmemh 跳过非数值行；文件路径由参数注入。 */
    initial begin
        total_words = MAX_WORD;
        $readmemh("case.hex", img);
        for (v_i = 0; v_i < MAX_WORD; v_i = v_i + 1) begin
            if (img[v_i] === 32'hx && total_words == MAX_WORD) begin
                total_words = v_i;
            end
        end
        if (total_words == 0) total_words = MAX_WORD;
    end

    /* 校验和：数值域低 30 位 + 符号位，累加 mod 2^31（对齐 C 侧 img_sum_word）。 */
    function [30:0] sum_word;
        input [31:0] w;
        begin
            sum_word = w[29:0] + w[30];
        end
    endfunction

    task set_error;
        input [3:0] code;
        begin
            loader_err      = 1'b1;
            loader_err_code = code;
            state           = S_ERROR;
        end
    endtask

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            loader_wr_en   <= 1'b0;
            loader_wr_addr <= 12'd0;
            loader_wr_data <= 31'd0;
            loader_done    <= 1'b0;
            loader_err     <= 1'b0;
            loader_err_code<= 4'd0;
            loader_entry   <= 12'd0;
            state          <= S_IDLE;
            seg_idx        <= 0;
            seg_k          <= 0;
            wipe_addr      <= 0;
            nseg           <= 0;
            entry_pc       <= 12'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    loader_wr_en <= 1'b0;
                    state        <= S_CHECK;
                end

                S_CHECK: begin
                    /* 1) 长度：头 2 字 + 段表 + 至少校验尾 1 字。 */
                    if (total_words < 3) begin
                        set_error(4'd1);
                    end else if (img[0] !== MAGIC) begin
                        set_error(4'd2);
                    end else begin
                        v_n      = img[1][11:0];
                        v_entry  = img[1][23:12];
                        v_ver    = img[1][30:27];
                        v_algo   = img[1][26:24];

                        if (v_ver !== 1 || v_algo !== 0) begin
                            set_error(4'd3);
                        end else if (v_n == 0 || v_n > MAX_SEG) begin
                            set_error(4'd4);
                        end else if (v_entry >= WORDS) begin
                            set_error(4'd5);
                        end else begin
                            v_body_start = 2 + 2*v_n;
                            v_body_words = 0;
                            v_ok = 1;

                            nseg     = v_n;
                            entry_pc = v_entry[11:0];

                            for (v_i = 0; v_i < v_n; v_i = v_i + 1) begin
                                v_a = img[2 + 2*v_i];
                                v_b = img[2 + 2*v_i + 1];
                                seg_dst[v_i]  = v_a[11:0];
                                seg_off[v_i]  = v_a[23:12];
                                seg_type[v_i] = v_a[26:24];
                                seg_len[v_i]  = v_b[11:0];

                                if (seg_type[v_i] > 3'd1) begin v_ok = 0; set_error(4'd6); end
                                else if (seg_len[v_i] == 0) begin v_ok = 0; set_error(4'd7); end
                                else if (seg_dst[v_i] + seg_len[v_i] > WORDS) begin v_ok = 0; set_error(4'd8); end
                                v_body_words = v_body_words + seg_len[v_i];
                            end

                            if (v_ok && (v_body_start + v_body_words + 1 != total_words)) begin
                                set_error(4'd11);
                                v_ok = 0;
                            end

                            if (v_ok) begin
                                for (v_i = 0; v_i < v_n; v_i = v_i + 1) begin
                                    if (seg_off[v_i] + seg_len[v_i] > v_body_words) begin
                                        set_error(4'd9);
                                        v_ok = 0;
                                    end
                                end
                            end

                            if (v_ok) begin
                                v_cksum = 31'd0;
                                for (v_i = 0; v_i < total_words - 1; v_i = v_i + 1) begin
                                    v_cksum = (v_cksum + sum_word(img[v_i])) & 31'h7fffffff;
                                end
                                if (v_cksum !== img[total_words-1][30:0]) begin
                                    set_error(4'd10);
                                    v_ok = 0;
                                end
                            end

                            if (v_ok) begin
                                wipe_addr <= 0;
                                state     <= S_WIPE;
                            end
                        end
                    end
                end

                S_WIPE: begin
                    loader_wr_en   <= 1'b1;
                    loader_wr_addr <= wipe_addr[11:0];
                    loader_wr_data <= 31'd0;
                    if (wipe_addr + 1 >= WORDS) begin
                        seg_idx   <= 0;
                        seg_k     <= 0;
                        state     <= S_LOAD;
                    end
                    wipe_addr <= wipe_addr + 1;
                end

                S_LOAD: begin
                    if (seg_idx >= nseg) begin
                        loader_wr_en <= 1'b0;
                        loader_entry <= entry_pc;
                        loader_done  <= 1'b1;
                        state        <= S_DONE;
                    end else begin
                        v_body_start = 2 + 2*nseg;
                        loader_wr_en   <= 1'b1;
                        loader_wr_addr <= seg_dst[seg_idx] + seg_k[11:0];
                        loader_wr_data <= img[v_body_start + seg_off[seg_idx] + seg_k][30:0];

                        if (seg_k + 1 >= seg_len[seg_idx]) begin
                            seg_idx <= seg_idx + 1;
                            seg_k   <= 0;
                        end else begin
                            seg_k <= seg_k + 1;
                        end
                    end
                end

                S_DONE:  loader_wr_en <= 1'b0;
                S_ERROR: loader_wr_en <= 1'b0;
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
