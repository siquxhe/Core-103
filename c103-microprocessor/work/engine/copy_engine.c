#include "copy_engine.h"

static uint8_t ce_check_bounds(const copy_engine_t *ce, uint16_t *err_code)
{
    /* 返回 1 = 合法；0 = 非法，err_code 写入原因。 */
    if (ce->len == 0u) {
        *err_code = CE_ERR_ZERO_LEN;
        return 0u;
    }

    const uint32_t size = ce->mem_size;
    const uint32_t src_last = (uint32_t)ce->src + ce->len - 1u;
    const uint32_t dst_last = (uint32_t)ce->dst + ce->len - 1u;

    if (ce->src >= size || src_last >= size) {
        *err_code = CE_ERR_SRC_OOB;
        return 0u;
    }
    if (ce->dst >= size || dst_last >= size) {
        *err_code = CE_ERR_DST_OOB;
        return 0u;
    }
    return 1u;
}

void ce_reset(copy_engine_t *ce)
{
    ce->src = 0;
    ce->dst = 0;
    ce->len = 0;
    ce->go = 0;

    ce->busy = 0;
    ce->done = 0;
    ce->err = 0;
    ce->err_code = CE_ERR_NONE;
    ce->entry = 0;

    ce->state = CE_IDLE;
    ce->src_ptr = 0;
    ce->dst_ptr = 0;
    ce->remain = 0;
    ce->latch_word = 0;
    ce->reverse = 0u;
}

void ce_bind_memory(copy_engine_t *ce,
                    const uint32_t *src_mem, uint32_t *dst_mem,
                    uint16_t mem_size)
{
    ce->src_mem = src_mem;
    ce->dst_mem = dst_mem;
    ce->mem_size = mem_size;
}

void ce_launch(copy_engine_t *ce, uint16_t src, uint16_t dst, uint16_t len)
{
    ce->src = src & CE_ADDR_MASK;
    ce->dst = dst & CE_ADDR_MASK;
    ce->len = len & CE_ADDR_MASK;
    ce->go = 1u;
}

void ce_step(copy_engine_t *ce)
{
    switch (ce->state) {
    case CE_IDLE:
        if (ce->go) {
            ce->go = 0u;
            ce->busy = 1u;
            ce->state = CE_ARM;
        }
        break;

    case CE_ARM: {
        uint8_t ok;
        uint16_t code = CE_ERR_NONE;
        ok = ce_check_bounds(ce, &code);
        if (!ok) {
            ce->err_code = code;
            ce->err = 1u;
            ce->busy = 0u;
            ce->state = CE_ERR;
        } else {
            uint32_t s_last = (uint32_t)ce->src + ce->len - 1u;
            uint32_t d_last = (uint32_t)ce->dst + ce->len - 1u;
            uint8_t  rev = (ce->dst > ce->src) && (ce->dst <= s_last);
            ce->reverse = rev;
            if (!rev) {
                ce->src_ptr = ce->src;
                ce->dst_ptr = ce->dst;
            } else {
                ce->src_ptr = (uint16_t)s_last;
                ce->dst_ptr = (uint16_t)d_last;
            }
            ce->remain = ce->len;
            ce->state = CE_FETCH;
        }
        break;
    }

    case CE_FETCH:
        ce->latch_word = ce->src_mem[ce->src_ptr];
        ce->state = CE_WRITE;
        break;

    case CE_WRITE:
        ce->dst_mem[ce->dst_ptr] = ce->latch_word;
        if (!ce->reverse) { ce->src_ptr++; ce->dst_ptr++; }
        else              { ce->src_ptr--; ce->dst_ptr--; }
        ce->remain--;
        ce->state = CE_CHECK;
        break;

    case CE_CHECK:
        if (ce->remain == 0u) {
            ce->busy = 0u;
            ce->done = 1u;
            ce->state = CE_DONE;
        } else {
            ce->state = CE_FETCH;
        }
        break;

    case CE_DONE:
        /* 等待核心 clear_done 握手，不自行迁移。 */
        break;

    case CE_ERR:
        /* 等待核心 clear_err 握手，不自行迁移。 */
        break;
    }
}

void ce_clear_done(copy_engine_t *ce)
{
    if (ce->state == CE_DONE) {
        ce->done = 0u;
        ce->state = CE_IDLE;
    }
}

void ce_clear_err(copy_engine_t *ce)
{
    if (ce->state == CE_ERR) {
        ce->err = 0u;
        ce->err_code = CE_ERR_NONE;
        ce->state = CE_IDLE;
    }
}

const char *ce_state_name(const copy_engine_t *ce)
{
    switch (ce->state) {
    case CE_IDLE:  return "IDLE";
    case CE_ARM:   return "ARM";
    case CE_FETCH: return "FETCH";
    case CE_WRITE: return "WRITE";
    case CE_CHECK: return "CHECK";
    case CE_DONE:  return "DONE";
    case CE_ERR:   return "ERR";
    default:       return "?";
    }
}
