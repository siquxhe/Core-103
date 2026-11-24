/**
 * 拷贝引擎行为模型自检测试台。
 * 用例：单块装载 / 长度精确停止 / 源越界 / 目的越界 / 零长度 /
 *       搬运中复位 / done 握手清除后可再装载。
 * 判据内置在测试台：每项 CHECK 打印 PASS/FAIL，汇总退出码。
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "copy_engine.h"

#define MEM_CAP   4096u
#define SENTINEL  0x55555555u
#define MAX_STEPS 10000u

static uint32_t src_mem[MEM_CAP];
static uint32_t dst_mem[MEM_CAP];

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
    checks++; \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { failures++; printf("  FAIL  %s\n", msg); } \
} while (0)

static void fill_patterns(void)
{
    for (uint32_t i = 0; i < MEM_CAP; ++i) {
        src_mem[i] = (i * 2654435761u) & CE_WORD_MASK;
        dst_mem[i] = SENTINEL;
    }
}

/** 推进到目标状态或超时；返回 1 到达，0 超时。 */
static int run_to(copy_engine_t *ce, ce_state_t target)
{
    for (uint32_t s = 0; s < MAX_STEPS; ++s) {
        if (ce->state == target) { return 1; }
        ce_step(ce);
    }
    return ce->state == target;
}

int main(void)
{
    copy_engine_t ce;
    ce_reset(&ce);
    ce_bind_memory(&ce, src_mem, dst_mem, MEM_CAP);

    /* ---- T1 单块装载 ---- */
    printf("[T1] single block load\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 0, 100, 16);
    CHECK(run_to(&ce, CE_DONE), "reach DONE");
    CHECK(ce.done == 1 && ce.err == 0, "done set, err clear");
    CHECK(ce.remain == 0, "remain counted to zero");
    {
        int match = 1;
        for (int i = 0; i < 16; ++i) {
            if (dst_mem[100 + i] != src_mem[i]) { match = 0; break; }
        }
        CHECK(match, "dst[100..115] == src[0..15]");
    }

    /* ---- T2 长度精确停止（哨兵不被覆盖） ---- */
    printf("[T2] exact length stop, sentinel preserved\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 20, 200, 5);
    run_to(&ce, CE_DONE);
    {
        int match = 1;
        for (int i = 0; i < 5; ++i) {
            if (dst_mem[200 + i] != src_mem[20 + i]) { match = 0; break; }
        }
        CHECK(match, "dst[200..204] == src[20..24]");
        CHECK(dst_mem[205] == SENTINEL, "dst[205] sentinel untouched");
    }

    /* ---- T3 源越界 ---- */
    printf("[T3] source out-of-bounds\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 4090, 300, 10);
    CHECK(run_to(&ce, CE_ERR), "reach ERR");
    CHECK(ce.err == 1 && ce.err_code == CE_ERR_SRC_OOB, "err_code = SRC_OOB");
    {
        int untouched = 1;
        for (int i = 0; i < 10; ++i) {
            if (dst_mem[300 + i] != SENTINEL) { untouched = 0; break; }
        }
        CHECK(untouched, "dst region not written on src fault");
    }

    /* ---- T4 目的越界 ---- */
    printf("[T4] destination out-of-bounds\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 0, 4090, 10);
    CHECK(run_to(&ce, CE_ERR), "reach ERR");
    CHECK(ce.err_code == CE_ERR_DST_OOB, "err_code = DST_OOB");

    /* ---- T5 零长度 ---- */
    printf("[T5] zero length\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 0, 400, 0);
    CHECK(run_to(&ce, CE_ERR), "reach ERR");
    CHECK(ce.err_code == CE_ERR_ZERO_LEN, "err_code = ZERO_LEN");

    /* ---- T6 搬运中复位 ---- */
    printf("[T6] reset mid-transfer\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 0, 500, 16);
    ce_step(&ce); ce_step(&ce); /* 进入 FETCH/WRITE 途中 */
    ce_reset(&ce);
    CHECK(ce.state == CE_IDLE, "state back to IDLE");
    CHECK(ce.busy == 0 && ce.done == 0 && ce.err == 0, "status flags cleared");

    /* ---- T7 握手清除后可再装载 ---- */
    printf("[T7] re-arm after done handshake\n");
    fill_patterns();
    ce_reset(&ce);
    ce_launch(&ce, 10, 600, 4);
    run_to(&ce, CE_DONE);
    ce_clear_done(&ce);
    CHECK(ce.state == CE_IDLE && ce.done == 0, "clear_done -> IDLE");
    ce_launch(&ce, 11, 610, 4);
    CHECK(run_to(&ce, CE_DONE), "second load reaches DONE");
    {
        int match = 1;
        for (int i = 0; i < 4; ++i) {
            if (dst_mem[610 + i] != src_mem[11 + i]) { match = 0; break; }
        }
        CHECK(match, "second block copied correctly");
    }

    printf("\n----------------------------------------\n");
    printf("checks: %d  failures: %d\n", checks, failures);
    if (failures == 0) {
        printf("RESULT: PASS\n");
        return 0;
    }
    printf("RESULT: FAIL\n");
    return 1;
}
