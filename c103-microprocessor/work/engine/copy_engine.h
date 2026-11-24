/**
 * 103 复刻 · 硬件拷贝引擎行为模型（C 原型）
 *
 * 对应设计文档：c103-microprocessor/07-硬件拷贝引擎设计.md 第 3、5 节。
 * 本文件为第一阶段 C 行为模型：不接主模拟器，独立可编译、可自检。
 * 后续 RTL 化时，寄存器位宽、状态命名与握手语义与本模型一一对应。
 *
 * 字宽：31 位（1 符号 + 30 数值），原型用 uint32_t 容器存放。
 * 地址：12 位（0..4095），原型 mem_size 可配置。
 */
#ifndef COPY_ENGINE_H
#define COPY_ENGINE_H

#include <stdint.h>

#define CE_ADDR_MASK   0x0FFFu
#define CE_WORD_MASK   0x7FFFFFFFu

/* 错误码 */
#define CE_ERR_NONE      0u
#define CE_ERR_SRC_OOB   1u   /* 源地址区间越界 */
#define CE_ERR_DST_OOB   2u   /* 目的地址区间越界 */
#define CE_ERR_ZERO_LEN  3u   /* 长度为 0 */

typedef enum {
    CE_IDLE = 0,
    CE_ARM,
    CE_FETCH,
    CE_WRITE,
    CE_CHECK,
    CE_DONE,
    CE_ERR
} ce_state_t;

typedef struct {
    /* ---- 命令寄存器（核心写） ---- */
    uint16_t src;        /* 镜像区源起始地址 */
    uint16_t dst;        /* RAM 目的起始地址 */
    uint16_t len;        /* 待搬字数 */
    uint8_t  go;         /* 启动脉冲（行为模型：launch 等效置位） */

    /* ---- 状态寄存器（引擎置） ---- */
    uint8_t  busy;
    uint8_t  done;
    uint8_t  err;
    uint8_t  err_code;
    uint16_t entry;      /* 可选：块头解析出的任务入口 */

    /* ---- 内部 FSM 状态 ---- */
    ce_state_t state;
    uint16_t src_ptr;
    uint16_t dst_ptr;
    uint16_t remain;
    uint32_t latch_word; /* FETCH 锁存的待写字 */

    /* ---- 内存抽象接口（外接，引擎不持有所有权） ---- */
    const uint32_t *src_mem;
    uint32_t       *dst_mem;
    uint16_t        mem_size;
} copy_engine_t;

/** 复位：所有寄存器与状态显式回到 IDLE（对应 07 文档 §5 复位要求）。 */
void ce_reset(copy_engine_t *ce);

/** 外接内存区与容量；src_mem/dst_mem 原型可指向同一数组。 */
void ce_bind_memory(copy_engine_t *ce,
                    const uint32_t *src_mem, uint32_t *dst_mem,
                    uint16_t mem_size);

/** 装载命令并发出启动脉冲（锁存 src/dst/len，下一 step 进入 ARM）。 */
void ce_launch(copy_engine_t *ce, uint16_t src, uint16_t dst, uint16_t len);

/** 推进 FSM 一拍（行为级单步，对应 RTL 一个时钟节拍）。 */
void ce_step(copy_engine_t *ce);

/** 握手清除：核心在 done 后调用，引擎回到 IDLE。 */
void ce_clear_done(copy_engine_t *ce);

/** 握手清除：核心在 err 后调用，引擎回到 IDLE。 */
void ce_clear_err(copy_engine_t *ce);

/** 当前 FSM 状态名（调试/日志用）。 */
const char *ce_state_name(const copy_engine_t *ce);

#endif /* COPY_ENGINE_H */
