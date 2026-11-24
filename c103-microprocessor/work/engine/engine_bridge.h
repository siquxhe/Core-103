/**
 * 拷贝引擎 ↔ 103 模拟器 接入桥（行为级）。
 *
 * 职责：
 *  - 在模拟器侧实例化拷贝引擎，并把它绑定到模拟器扁平内存 machine_mem；
 *  - 封装装载协议：参数下发(src/dst/len) → go 启动 → 轮询 busy → done/err 握手；
 *  - 不改内核译码、节拍与指令集；引擎作为外挂外设，核心通路保持原 103 行为。
 *
 * 对应 07 文档 §6 配合流程：核心向引擎寄存器写 src/dst/len 并发 go，
 * 轮询 busy，引擎独占写口搬完整块，done 后核心登记入口/上下文。
 */
#ifndef ENGINE_BRIDGE_H
#define ENGINE_BRIDGE_H

#include <stdint.h>
#include "copy_engine.h"

typedef struct {
    copy_engine_t ce;
    uint16_t      mem_size;
} engine_bridge_t;

/** 初始化桥与引擎；mem_size 一般取模拟器内存容量（4096 字）。 */
void eng_bridge_init(engine_bridge_t *b, uint16_t mem_size);

/** 绑定模拟器内存 machine_mem（扁平内存：源区与目的区同一块）。 */
void eng_bridge_bind_sim_memory(engine_bridge_t *b);

/** 下发装载参数并发出启动脉冲（等价核心写命令寄存器 + go）。 */
void eng_bridge_load(engine_bridge_t *b, uint16_t src, uint16_t dst, uint16_t len);

/** 推进引擎 FSM 一拍（行为级单步；RTL 化后对应一个时钟节拍）。 */
void eng_bridge_poll(engine_bridge_t *b);

/** 状态查询。 */
int      eng_bridge_busy(const engine_bridge_t *b);
int      eng_bridge_done(const engine_bridge_t *b);
int      eng_bridge_err(const engine_bridge_t *b);
uint8_t  eng_bridge_err_code(const engine_bridge_t *b);
uint16_t eng_bridge_remain(const engine_bridge_t *b);

/** 完成握手：核心在 done 后调用，引擎回 IDLE。 */
void eng_bridge_ack_done(engine_bridge_t *b);

/** 错误握手：核心在 err 后调用，引擎回 IDLE。 */
void eng_bridge_ack_err(engine_bridge_t *b);

#endif /* ENGINE_BRIDGE_H */
