# 会话级 Prefix KV Cache 复用架构（流式 ASR 增量 Prefill）

> 状态：设计定案 + 骨架代码（`Sources/Pipeline/ASR/KVCache/`）。MLX 张量算子为
> `#if canImport(MLXNN)` 守卫的骨架——签名与数据布局已定案，待接入 mlx-swift
> 后填充并验证。状态管理器（KVCacheSession）为纯逻辑、已编译、已单测。

## 1. 问题与适用边界（先说清楚给谁用）

连续流式 ASR 的每一轮识别 = 重转录「未封口 tail + 历史转录 Prompt 上下文」。
设缓存前缀 C 个 token、本轮新增 N 个 token，全量 Prefill 的注意力计算量为
`(C+N)²/2`，其中重复计算前缀的部分是纯浪费。

**现有五个引擎的现实约束**：

| 引擎 | 现状 | 能否复用本方案 |
|---|---|---|
| Whisper（whisper.cpp） | `whisper_full` 无状态，KV 不外露 | ❌ C API 不暴露缓存写接口 |
| Qwen3-ASR（transcribe.cpp） | 同上，ggml 会话内部持有 | ❌ 同上 |
| FunASR（sherpa-onnx） | online 流式已带内部状态 | ❌（已有水位线去重） |
| Apple Speech | 系统流式会话 | ❌（已有水位线去重） |
| **MLX 音频-LLM 路线**（Qwen3-Audio 类 decoder-only，mlx-swift） | 尚未接入 | ✅ **本方案的目标载体** |

结论：`KVCacheSession` 是**引擎无关**的状态管理器（纯逻辑，已单测），
MLX 后端是第一个（也是设计初衷的）物理实现。当前管线的无状态引擎每轮
只重转录 ≤12s tail（ASRManager 已有 tail 窗口控制），浪费上限有界；
真正吃满 40%~60% 节省的是「长上下文 Prompt + 每轮全量 Prefill」的
decoder-only 音频 LLM 路线。

## 2. 会话生命周期与状态

```
录制开始（ASRManager.start）──→ KVCacheSession.init（预分配物理缓存）
│
├─ 每轮识别：增量 Prefill（§3）→ 追加 K/V → 解码
│
├─ [触发重置的三个信号源]
│   ① 上下文超限   → 滑动窗口裁剪（§5-A）或全量重建
│   ② 静音切段/换题 → invalidate(.silenceSeal / .topicChange)
│   ③ 音频不连续   → invalidate(.streamDiscontinuity)
│      （RealtimeAudioIngest.takeDiscontinuity()：环形缓冲覆盖丢弃时置位）
│
└─ 录制结束（stop）──→ deinit：统一内存释放
```

会话与**录制会话**严格绑定：跨会话不复用（新会话第一句不受上一会话末句
影响——与 SubtitleManager.resetSubtitleDisplay(clearMemory: true) 同一纪律）。

## 3. 增量 Prefill：数据流与注意力矩阵

### 3.1 数据流

```
新音频块（16k mono，来自 SPSC 环形缓冲）
  → 音频编码器（仅对新增帧）→ N 个 audio token
  → [可选] 拼接本轮 prompt 增量（如刚封口句的 transcript token）
  → KVCacheSession.prefillIncremental(newTokenIDs)
       ├─ planAppend：容量规划（§5）
       ├─ positions = cachedPrefixLength ..< cachedPrefixLength+N   ← 自增偏移
       ├─ mask：前缀区全 1 可 attend + 新区因果                      ← 动态修正
       ├─ backend.computeNewKV(tokens, positions, mask)              ← 只算新增
       ├─ backend.write(offset: cachedPrefixLength, k, v)            ← 追加入池
       └─ cachedPrefixLength += N（发布）
  → decodeStep：单 token Q(1×d) attend 全部 C+N 个缓存 K/V
```

### 3.2 注意力矩阵变化（节省量推导）

全量 Prefill（因果）：score 矩阵 `(C+N) × (C+N)`，≈ `(C+N)²/2` MAC。

增量 Prefill：Q 只有 N 行，K/V = [缓存 C | 新 N]：

```
        K_cached(C)   K_new(N)
Q_new(N)   可 attend    可 attend      → N·C + N·(N+1)/2 ≈ N·C + N²/2
K/V 旧区   不重算        不重算          （缓存的 K/V 原样复用）
```

节省 `1 − (N·C + N²/2) / ((C+N)²/2)`：

| C（缓存） | N（新增） | 全量 | 增量 | 节省 |
|---|---|---|---|---|
| 1000 | 500 | 1.13M | 0.63M | **44%** |
| 2000 | 200 | 2.42M | 0.42M | **83%** |

N/C 越小节省越大——长会话稳态（tail 增量远小于累计上下文）落在 40%~90%。

### 3.3 attention_mask 动态修正

增量 Prefill 的 mask 只需构造**新增 N 行**（缓存区行的注意力在当初写入时
已经完成、结果固化在 K/V 里，不再参与本轮计算）：

```
新 token j（全局位置 C+j）可 attend：[0 ..< C+j]，共 C+j+1 个
即 attendableCounts = [C+1, C+2, …, C+N]
```

解码步（单 token）：一行全 1（长度 C+N+1）。

### 3.4 position_ids 与 RoPE 连续性

- 增量 token 的 `position_ids = arange(C, C+N)`——绝对位置连续自增；
- 缓存中的 K/V 在写入时**已应用对应位置的 RoPE**（MLX 注意力在 QK 内积前
  按 position 旋转），因此续算无需触碰缓存；
- RoPE 错位的唯一来源是**裁剪后窗口平移**（§5-A），处理见下。

## 4. 编码器侧复用的语义差异（必须声明）

- **decoder 侧**（transcript prompt 自回归）：因果注意力天然兼容前缀缓存，
  增量 Prefill 与全量 Prefill **数学等价**——精确复用。
- **audio encoder 侧**：编码器是双向注意力。前缀复用等价于把编码器改成
  「prefix-LM 掩码」——旧音频 token 不再 attend 新音频 token，与全量重编码
  **数学不等价**（差异集中在跨块边界）。
  - 缓解：块重叠 ≥1s 时边界差异被 ASR 容错吸收；
  - 上线前必须 A/B 验证 CER（同音频：全量 prefill vs 增量 prefill）；
  - 保守替代：只对 decoder/prompt 侧做 KV 复用，encoder 每轮只编码新增帧
    （encoder 本身按块因果化）。

## 5. 淘汰与重置策略

### A. 滑动窗口裁剪（上下文超限，保留话题连续性）

触发：`cachedPrefixLength + N > maxContextTokens`，且 `N ≤ keepTargetTokens`。

- 裁掉最旧 `E = cachedPrefixLength + N − keepTargetTokens` 个 token；
- 物理实现二选一：
  1. **RoPE 旋转移位**（精确、O(L·d/2) 复数乘）：RoPE 是旋转——把缓存 K 的
     位置从 p 平移到 p−E，等价于对每对旋转分量乘 `e^(−iE·θ_i)`，缓存的
     注意力内容完整保留，只改相位；
  2. **重 Prefill 窗口**（简单、一次性 O(W²)）：清缓存后对保留的
     keepTarget 窗口重新 prefill。W 取小时代价可忽略，无数学风险。
- 骨架默认策略：**方案 2**（正确性优先，旋转移位作为优化项后续填充）。

### B. 安全 Evict（信号源 ②③，全量重建）

| 信号 | 检测点 | 处置 |
|---|---|---|
| 静音切段 | `SubtitleManager.sealSilence` 后长静音 | `invalidate(.silenceSeal)`（可配：同话题连续语音可不重置） |
| 换题 | 显式用户操作 / 转录文本相似度骤降（后置） | `invalidate(.topicChange)` |
| 音频不连续 | `RealtimeAudioIngest.takeDiscontinuity()`（环形缓冲覆盖丢弃） | `invalidate(.streamDiscontinuity)`——**必须**重置：丢失的音频使缓存上下文与真实流错位，续用会产生幻觉 |

### C. 单块新增超过保留目标

`N > keepTargetTokens`（如超长独白）→ 不裁剪（裁了也装不下），直接
`reset` 后对最近 keepTarget 窗口重 prefill。

## 6. 与既有管线的对接点

- **ASRManager.start/stopRecording** → session 生命周期；
- **RealtimeAudioIngest.takeDiscontinuity()**（P1 采集前端）→ 强制重置信号；
- **StreamingFeedWaterline**（流式引擎音频去重）与本方案是同一思想的两层：
  waterline = 音频级「不重喂」，KVCacheSession = KV 级「不重算」；
- **InputBucketing**：桶化补零的形状稳定性收益与增量 prefill 正交，可叠加。

## 7. 风险与验证计划

1. CER A/B：同一长音频，全量 Prefill vs 增量 Prefill（decoder 精确、encoder 近似）；
2. 基准：单位 token prefill 耗时 + 峰值功耗（目标：稳态省 ≥40%）；
3. 长会话压力：连续 60min 音频，验证滑窗裁剪后无位置错位（错位表现为
   重复字/幻听——RoPE 相位断层的典型症状）；
4. 内存：maxContextTokens 预分配上限 = 层数 × kv 头数 × maxCtx × headDim
   × 2(K+V) × 4B——例：24 层 × 8 头 × 8192 × 128 × 2 × 4B ≈ 1.6GB 统一内存，
   需按设备档位收敛 maxCtx。
