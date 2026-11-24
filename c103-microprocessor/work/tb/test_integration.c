/**
 * 拷贝引擎 ↔ 103 模拟器 集成测试。
 *
 * 验证点：
 *  - 引擎绑定的是模拟器 machine_mem 同一数组（不是副本）；
 *  - 单块装载：参数下发 → go → 轮询 busy → done → 握手回 IDLE，数据逐字落位；
 *  - 多块依次装入：两块各自 done，目的区不串扰；
 *  - 越界经桥接透传 err_code，目的区不被写；
 *  - 完成/错误握手后引擎回 IDLE，可再次装载。
 *
 * 不调用 run_machine()：本阶段只验证装载协议与数据通路，核心执行装入代码留下一步。
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "103.h"            /* machine_mem, init_mem */
#include "engine_bridge.h"

#define MEM_CAP   4096u
#define SENTINEL  0x55555555u
#define MAX_STEPS 10000u

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
    checks++; \
    if (cond) { printf("  PASS  %s\n", msg); } \
    else { failures++; printf("  FAIL  %s\n", msg); } \
} while (0)

/** 轮询直到 done 或 err；返回 1 到达终止态，0 超时。 */
static int run_to_terminal(engine_bridge_t *b)
{
    for (uint32_t s = 0; s < MAX_STEPS; ++s) {
        if (eng_bridge_done(b) || eng_bridge_err(b)) { return 1; }
        eng_bridge_poll(b);
    }
    return eng_bridge_done(b) || eng_bridge_err(b);
}

static void fill_region(uint16_t base, uint16_t len, uint32_t seed)
{
    for (uint16_t i = 0; i < len; ++i) {
        machine_mem[base + i] = (seed + i * 2654435761u) & 0x7FFFFFFFu;
    }
}

static void stamp_sentinel(uint16_t base, uint16_t len)
{
    for (uint16_t i = 0; i < len; ++i) {
        machine_mem[base + i] = SENTINEL;
    }
}

int main(void)
{
    init_mem();   /* 分配 machine_mem[4096] */

    engine_bridge_t bridge;
    eng_bridge_init(&bridge, MEM_CAP);
    eng_bridge_bind_sim_memory(&bridge);

    /* ---- I1 单块装载 ---- */
    printf("[I1] single block load into simulator memory\n");
    const uint16_t src1 = 03000, dst1 = 01000, len1 = 12;
    fill_region(src1, len1, 0x111);
    stamp_sentinel(dst1, len1 + 4);

    eng_bridge_load(&bridge, src1, dst1, len1);
    CHECK(run_to_terminal(&bridge), "reach terminal (done/err)");
    CHECK(eng_bridge_done(&bridge) == 1 && eng_bridge_err(&bridge) == 0, "done set, err clear");
    CHECK(eng_bridge_remain(&bridge) == 0, "remain counted to zero");
    {
        int match = 1;
        for (uint16_t i = 0; i < len1; ++i) {
            if (machine_mem[dst1 + i] != machine_mem[src1 + i]) { match = 0; break; }
        }
        CHECK(match, "dst words == src words in machine_mem");
    }
    CHECK(machine_mem[dst1 + len1] == SENTINEL, "trailing sentinel untouched");
    eng_bridge_ack_done(&bridge);
    CHECK(!eng_bridge_busy(&bridge), "after ack_done, busy clear");

    /* ---- I2 多块依次装入 ---- */
    printf("[I2] two blocks loaded sequentially\n");
    const uint16_t srcA = 03100, dstA = 01200, lenA = 8;
    const uint16_t srcB = 03200, dstB = 01400, lenB = 8;
    fill_region(srcA, lenA, 0x222);
    fill_region(srcB, lenB, 0x333);
    stamp_sentinel(dstA, lenA + 2);
    stamp_sentinel(dstB, lenB + 2);

    eng_bridge_load(&bridge, srcA, dstA, lenA);
    run_to_terminal(&bridge);
    CHECK(eng_bridge_done(&bridge), "block A done");
    eng_bridge_ack_done(&bridge);

    eng_bridge_load(&bridge, srcB, dstB, lenB);
    run_to_terminal(&bridge);
    CHECK(eng_bridge_done(&bridge), "block B done");
    eng_bridge_ack_done(&bridge);

    {
        int matchA = 1, matchB = 1;
        for (uint16_t i = 0; i < lenA; ++i)
            if (machine_mem[dstA + i] != machine_mem[srcA + i]) { matchA = 0; break; }
        for (uint16_t i = 0; i < lenB; ++i)
            if (machine_mem[dstB + i] != machine_mem[srcB + i]) { matchB = 0; break; }
        CHECK(matchA, "block A copied correctly");
        CHECK(matchB, "block B copied correctly");
        CHECK(machine_mem[dstA + lenA] == SENTINEL && machine_mem[dstB + lenB] == SENTINEL,
              "no cross-block overwrite");
    }

    /* ---- I3 越界经桥接透传 ---- */
    printf("[I3] source out-of-bounds propagates through bridge\n");
    stamp_sentinel(03000, 16);
    eng_bridge_load(&bridge, 4090, 03000, 10);
    CHECK(run_to_terminal(&bridge), "reach ERR terminal");
    CHECK(eng_bridge_err(&bridge) == 1, "err set");
    CHECK(eng_bridge_err_code(&bridge) == CE_ERR_SRC_OOB, "err_code = SRC_OOB");
    {
        int untouched = 1;
        for (int i = 0; i < 10; ++i)
            if (machine_mem[03000 + i] != SENTINEL) { untouched = 0; break; }
        CHECK(untouched, "dst region not written on fault");
    }
    eng_bridge_ack_err(&bridge);
    CHECK(!eng_bridge_busy(&bridge), "after ack_err, busy clear");

    /* ---- I4 握手后可再次装载（回 IDLE 复装） ---- */
    printf("[I4] re-arm after handshake\n");
    fill_region(src1, len1, 0x444);
    stamp_sentinel(dst1, len1);
    eng_bridge_load(&bridge, src1, dst1, len1);
    run_to_terminal(&bridge);
    CHECK(eng_bridge_done(&bridge), "re-arm load done");
    {
        int match = 1;
        for (uint16_t i = 0; i < len1; ++i)
            if (machine_mem[dst1 + i] != machine_mem[src1 + i]) { match = 0; break; }
        CHECK(match, "re-arm block copied correctly");
    }

    printf("\n----------------------------------------\n");
    printf("checks: %d  failures: %d\n", checks, failures);
    if (failures == 0) { printf("RESULT: PASS\n"); return 0; }
    printf("RESULT: FAIL\n");
    return 1;
}
