/**
 * P0-2 镜像加载器报错路径冒烟 testbench（路线 A）
 *
 * 与正向 tb 相同的 memory + loader 连线；判据：
 *  1. loader 进入 ERROR（loader_err=1，loader_done=0）；
 *  2. loader_err_code 等于 EXPECT_ERR_CODE；
 *  3. 出错前不得向主存写数（loader_wr_en 在 ERROR 到达后保持 0）。
 *
 * 期望错误码通过 iverilog `-P tb_image_loader_err.EXPECT_ERR_CODE=<n>` 覆盖；
 * 对应坏镜像文本由回归脚本复制为 case.hex。
 */
`timescale 1ns/1ps

module tb_image_loader_err #(
    parameter integer EXPECT_ERR_CODE = 4'd2
)(
);

    localparam integer WORDS = 2048;

    reg clk;
    reg resetn;

    reg         mem_read_from_pu, mem_read_from_pnl;
    reg         mem_write_from_io, mem_write_from_pnl;
    reg  [11:0] sel_value_from_sel;
    reg         write_sign_from_ac;
    reg  [29:0] write_data_from_au;
    wire        mem_read_reply_to_pu, mem_read_reply_to_ac;
    wire        mem_write_reply_to_op, mem_write_reply_to_io, mem_reply_to_io;
    wire        read_sign_to_ac;
    wire [29:0] read_data_to_au;

    wire        eng_rd_req, eng_wr_req;
    wire [11:0] eng_rd_addr, eng_wr_addr;
    wire [30:0] eng_rd_data, eng_wr_data;

    wire         loader_wr_en;
    wire [11:0]  loader_wr_addr;
    wire [30:0]  loader_wr_data;
    wire         loader_done, loader_err;
    wire [3:0]   loader_err_code;
    wire [11:0]  loader_entry;

    reg  [11:0] dbg_rd_addr;
    wire [30:0] dbg_rd_data;

    wire grant_cpu, grant_eng, arb_conflict, cpu_stall, eng_stall;

    integer pass, fail;
    integer wrote_after_err;

    initial clk = 1'b0;
    always #1 clk = ~clk;

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

    /* 监视：进入 ERROR 之后不应再有写使能。 */
    always @(posedge clk) begin
        if (loader_err && loader_wr_en) wrote_after_err = wrote_after_err + 1;
    end

    initial begin
        resetn = 1'b0;
        mem_read_from_pu = 0; mem_read_from_pnl = 0;
        mem_write_from_io = 0; mem_write_from_pnl = 0;
        sel_value_from_sel = 12'd0;
        write_sign_from_ac = 1'b0; write_data_from_au = 30'd0;
        dbg_rd_addr = 12'd0;
        pass = 0; fail = 0; wrote_after_err = 0;

        #8 resetn = 1'b1;

        wait (loader_done || loader_err);
        @(negedge clk);

        if (loader_err) pass = pass + 1;
        else begin
            $display("FAIL: expected error code=%0d but loader DONE", EXPECT_ERR_CODE);
            fail = fail + 1;
        end

        if (loader_err_code === EXPECT_ERR_CODE) pass = pass + 1;
        else begin
            $display("FAIL err_code: got %0d expect %0d", loader_err_code, EXPECT_ERR_CODE);
            fail = fail + 1;
        end

        if (!loader_done) pass = pass + 1;
        else begin
            $display("FAIL: loader_done asserted on error path");
            fail = fail + 1;
        end

        #4;
        if (wrote_after_err == 0) pass = pass + 1;
        else begin
            $display("FAIL: wrote %0d words after error", wrote_after_err);
            fail = fail + 1;
        end

        $display("IMAGE-LOADER-ERR PASS=%0d FAIL=%0d code=%0d", pass, fail, loader_err_code);
        if (fail == 0) $display("RESULT: PASS");
        else           $display("RESULT: FAIL");
        #10 $finish;
    end

endmodule
