/**
 * P0-2 镜像加载器正向 testbench（路线 A 仿真闭环）
 *
 * 实例化 memory 行为模型 + image_loader；加载器经 dbg 写口把结构化镜像
 * 逐段落入主存。判据：
 *  1. loader 完成且无错误（loader_err=0）；
 *  2. 各段目的区逐字等于镜像体对应字；
 *  3. 未装载区被清零（加载前先清主存）；
 *  4. 入口 PC 与目录头一致。
 *
 * 镜像文本由打包器 image-pack --hex 生成（纯十六进制，每行一字）。
 */
`timescale 1ns/1ps

module tb_image_loader;

    localparam integer WORDS = 2048;

    reg clk;
    reg resetn;

    /* memory CPU 通路（本 tb 不驱动，接 0） */
    reg         mem_read_from_pu, mem_read_from_pnl;
    reg         mem_write_from_io, mem_write_from_pnl;
    reg  [11:0] sel_value_from_sel;
    reg         write_sign_from_ac;
    reg  [29:0] write_data_from_au;
    wire        mem_read_reply_to_pu, mem_read_reply_to_ac;
    wire        mem_write_reply_to_op, mem_write_reply_to_io, mem_reply_to_io;
    wire        read_sign_to_ac;
    wire [29:0] read_data_to_au;

    /* 引擎旁路（本 tb 不接） */
    wire        eng_rd_req, eng_wr_req;
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire [30:0] eng_rd_data, eng_wr_data;

    /* 加载器 -> memory dbg 写口 */
    wire         loader_wr_en;
    wire [11:0]  loader_wr_addr;
    wire [30:0]  loader_wr_data;
    wire         loader_done, loader_err;
    wire [3:0]   loader_err_code;
    wire [11:0]  loader_entry;

    /* dbg 读回 */
    reg  [11:0] dbg_rd_addr;
    wire [30:0] dbg_rd_data;

    wire grant_cpu, grant_eng, arb_conflict, cpu_stall, eng_stall;

    /* 本地镜像副本（期望基准） */
    reg [31:0] timg [0:4095];
    integer    total_words;

    integer i, k, pass, fail;
    integer v_n, v_entry, v_body_start, v_dst, v_off, v_len;
    reg [31:0] v_a, v_b;

    initial clk = 1'b0;
    always #1 clk = ~clk;

    /* DUT: memory */
    memory #(.WORDS(WORDS)) u_mem (
        .clk(clk),
        .resetn(resetn),
        .mem_read_from_pu(mem_read_from_pu),
        .mem_read_from_pnl(mem_read_from_pnl),
        .mem_write_from_io(mem_write_from_io),
        .mem_write_from_pnl(mem_write_from_pnl),
        .mem_read_reply_to_pu(mem_read_reply_to_pu),
        .mem_read_reply_to_ac(mem_read_reply_to_ac),
        .mem_write_reply_to_op(mem_write_reply_to_op),
        .mem_write_reply_to_io(mem_write_reply_to_io),
        .mem_reply_to_io(mem_reply_to_io),
        .sel_value_from_sel(sel_value_from_sel),
        .write_sign_from_ac(write_sign_from_ac),
        .write_data_from_au(write_data_from_au),
        .read_sign_to_ac(read_sign_to_ac),
        .read_data_to_au(read_data_to_au),

        .eng_rd_req(eng_rd_req),
        .eng_rd_addr(eng_rd_addr),
        .eng_rd_data(eng_rd_data),
        .eng_wr_req(eng_wr_req),
        .eng_wr_addr(eng_wr_addr),
        .eng_wr_data(eng_wr_data),

        .ctrl_rd_req(1'b0),
        .ctrl_rd_addr(12'd0),
        .ctrl_rd_data(),
        .ctrl_wr_req(1'b0),
        .ctrl_wr_addr(12'd0),
        .ctrl_wr_data(31'd0),

        .dbg_wr_en(loader_wr_en),
        .dbg_wr_addr(loader_wr_addr),
        .dbg_wr_data(loader_wr_data),
        .dbg_rd_addr(dbg_rd_addr),
        .dbg_rd_data(dbg_rd_data),

        .grant_cpu(grant_cpu),
        .grant_eng(grant_eng),
        .arb_conflict(arb_conflict),
        .cpu_stall(cpu_stall),
        .eng_stall(eng_stall),
        .cmd_wr_en(),
        .cmd_wr_addr(),
        .cmd_wr_data()
    );

    /* DUT: image loader */
    image_loader #(.WORDS(WORDS)) u_loader (
        .clk(clk),
        .resetn(resetn),
        .loader_wr_en(loader_wr_en),
        .loader_wr_addr(loader_wr_addr),
        .loader_wr_data(loader_wr_data),
        .loader_done(loader_done),
        .loader_err(loader_err),
        .loader_err_code(loader_err_code),
        .loader_entry(loader_entry)
    );

    initial begin
        resetn = 1'b0;
        mem_read_from_pu = 0; mem_read_from_pnl = 0;
        mem_write_from_io = 0; mem_write_from_pnl = 0;
        sel_value_from_sel = 12'd0;
        write_sign_from_ac = 1'b0; write_data_from_au = 30'd0;
        dbg_rd_addr = 12'd0;
        pass = 0; fail = 0;

        /* 读入期望镜像 */
        total_words = 4096;
        $readmemh("case.hex", timg);
        for (i = 0; i < 4096; i = i + 1) begin
            if (timg[i] === 32'hx && total_words == 4096) total_words = i;
        end
        if (total_words == 0) total_words = 4096;

        #8 resetn = 1'b1;

        /* 等待加载完成或出错 */
        wait (loader_done || loader_err);
        @(negedge clk);

        if (loader_err) begin
            $display("FAIL: loader error code=%0d", loader_err_code);
            fail = fail + 1;
        end else begin
            $display("loader DONE, entry=%04o", loader_entry);
        end

        if (!loader_err) begin
            v_n       = timg[1][11:0];
            v_entry   = timg[1][23:12];
            v_body_start = 2 + 2*v_n;

            /* 入口 PC 一致 */
            if (loader_entry === v_entry) pass = pass + 1;
            else begin
                $display("FAIL entry: got %04o expect %04o", loader_entry, v_entry);
                fail = fail + 1;
            end

            /* 逐段读回比对 */
            for (i = 0; i < v_n; i = i + 1) begin
                v_a   = timg[2 + 2*i];
                v_b   = timg[2 + 2*i + 1];
                v_dst = v_a[11:0];
                v_off = v_a[23:12];
                v_len = v_b[11:0];
                for (k = 0; k < v_len; k = k + 1) begin
                    dbg_rd_addr = v_dst + k;
                    @(negedge clk);
                    if (dbg_rd_data === timg[v_body_start + v_off + k][30:0]) begin
                        pass = pass + 1;
                    end else begin
                        $display("FAIL seg%0d[%0d] @%04o: got %h expect %h",
                                 i, k, v_dst+k, dbg_rd_data,
                                 timg[v_body_start + v_off + k][30:0]);
                        fail = fail + 1;
                    end
                end
            end

            /* 未装载区抽查：地址 0o2000 不在 0000-1200 / 3000-3777 段内，应为 0。 */
            dbg_rd_addr = 12'o2000;
            @(negedge clk);
            if (dbg_rd_data === 31'd0) pass = pass + 1;
            else begin
                $display("FAIL wipe: mem[2000]=%h 非零", dbg_rd_data);
                fail = fail + 1;
            end
        end

        $display("IMAGE-LOADER PASS=%0d FAIL=%0d", pass, fail);
        if (fail == 0) begin
            $display("RESULT: PASS");
        end else begin
            $display("RESULT: FAIL");
        end
        #10 $finish;
    end

endmodule
