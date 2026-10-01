#include "CRealtimeAtomics.h"

// 本 target 的原子 API 全部是 static inline（见头文件说明）：编译期内联为
// 单条 load/store 指令，链接期不产生符号。这里提供一个真实编译单元，让
// target 产出对象文件——否则纯头文件 target 会在链接期失败。

uint32_t cra_shim_version(void) {
    return 1;
}