#ifndef C_REALTIME_ATOMICS_H
#define C_REALTIME_ATOMICS_H

// MARK: - C11 原子操作 shim（SPSC 环形缓冲专用）
//
// Swift 不直接暴露 C11 的 _Atomic 类型与 memory_order 枚举；本头文件以
// static inline 函数（编译期内联为单条 load/store 指令 + 必要屏障）
// 暴露 SPSC 游标所需的三种内存顺序。
//
// 线程安全假设：p 必须指向**自然对齐的 8 字节存储**（调用方以
// UnsafeMutablePointer<UInt64>.allocate 分配即满足）；同一游标槽位
// 遵循「单写者」规则（SPSC 契约），本 shim 不提供 RMW 原子。

#include <stdint.h>
#include <stdatomic.h>

/// 宽松读：仅保证原子性，无同步语义。
/// 用途：读**本线程私有**游标（生产者读 head / 消费者读 tail）——
/// 自写自读，无需屏障。
static inline uint64_t cra_load_relaxed(const void *p) {
    return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_relaxed);
}

/// 获取读（acquire）：禁止本 load 之后的读写重排到它之前，
/// 并与对方的 release store 配对构成同步关系（happens-before）。
/// 用途：读**对方线程发布**的游标——保证看到对方游标推进的同时，
/// 也看到对方在发布前写入的全部数据。
static inline uint64_t cra_load_acquire(const void *p) {
    return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_acquire);
}

/// 释放写（release）：本 store 之前的全部读写不得重排到它之后。
/// 用途：数据落盘后发布游标——对方 acquire 到新游标时，
/// 必然能看到游标推进之前写入的样本。
static inline void cra_store_release(void *p, uint64_t v) {
    atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_release);
}

/// 宽松写：仅保证原子性，无同步语义。
/// 用途：复位（仅在缓冲区静默、双方线程均停时调用）。
static inline void cra_store_relaxed(void *p, uint64_t v) {
    atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_relaxed);
}

/// shim 版本锚点（非 inline，定义在 CRealtimeAtomics.c）。
///
/// 本 target 的原子 API 全部是 static inline——编译期内联，链接期无符号。
/// 但构建系统（swiftbuild 引擎）要求每个 target 产出对象文件，纯头文件
/// target 会在链接期报 "Build input file cannot be found: .../CRealtimeAtomics.o"。
/// 保留一个真实编译单元作为锚点即可满足该要求。
uint32_t cra_shim_version(void);

#endif /* C_REALTIME_ATOMICS_H */
