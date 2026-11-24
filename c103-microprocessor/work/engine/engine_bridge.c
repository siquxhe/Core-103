#include "engine_bridge.h"
#include "103.h"   /* machine_mem, num_t */

void eng_bridge_init(engine_bridge_t *b, uint16_t mem_size)
{
    ce_reset(&b->ce);
    b->mem_size = mem_size;
}

void eng_bridge_bind_sim_memory(engine_bridge_t *b)
{
    /* 扁平内存：源镜像区与目的任务区同属 machine_mem；
       num_t 与 uint32_t 位宽一致，直接强转绑定。 */
    ce_bind_memory(&b->ce,
                   (const uint32_t *)machine_mem,
                   (uint32_t *)machine_mem,
                   b->mem_size);
}

void eng_bridge_load(engine_bridge_t *b, uint16_t src, uint16_t dst, uint16_t len)
{
    ce_launch(&b->ce, src, dst, len);
}

void eng_bridge_poll(engine_bridge_t *b)
{
    ce_step(&b->ce);
}

int eng_bridge_busy(const engine_bridge_t *b)   { return b->ce.busy; }
int eng_bridge_done(const engine_bridge_t *b)   { return b->ce.done; }
int eng_bridge_err(const engine_bridge_t *b)    { return b->ce.err; }
uint8_t eng_bridge_err_code(const engine_bridge_t *b) { return b->ce.err_code; }
uint16_t eng_bridge_remain(const engine_bridge_t *b)   { return b->ce.remain; }

void eng_bridge_ack_done(engine_bridge_t *b)
{
    ce_clear_done(&b->ce);
}

void eng_bridge_ack_err(engine_bridge_t *b)
{
    ce_clear_err(&b->ce);
}
