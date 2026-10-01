#include <metal_stdlib>
using namespace metal;

// MARK: - 字词高亮字幕渲染管线（SDF 文本 + 词级进度高亮）
//
// 设计文档：与 MetalSubtitleRenderer.swift 配套（结构体字节布局必须一致）。
//
// 渲染模型：
//   - 字形几何由 Swift 侧在「文本/词边界变化」时一次性展开为 quad
//     （4 顶点 + 2 三角形），60~120fps 的进度刷新只更新 Uniforms；
//   - 字形纹理为 SDF（Signed Distance Field）单通道图集：r 通道存储
//     到字形边缘的有符号距离，0.5 = 边缘（平滑区间由 Uniforms 控制）；
//   - 词级高亮：Uniforms.progress = 3.4 表示第 0~2 词已完成、第 3 词
//     过渡 40%——片段着色器按词索引线性插值，杜绝阶梯跳跃。

// 顶点数据（与 Swift SubtitleGPUVertex 逐字节一致）：
//   position  像素坐标，y 向下（AppKit layer 左上原点）
//   uv        SDF 图集归一化坐标
//   wordIndex 所属词索引（quad 内四顶点同值）
struct SubtitleVertex {
    float2 position;
    float2 uv;
    float  wordIndex;
};

// 帧常量（与 Swift SubtitleUniforms 逐字节一致，48 字节）：
//   viewportSize  drawable 像素尺寸
//   progress      词级浮点进度（3.4 = 第 4 词过渡 40%）
//   sdfSmoothing  SDF 边缘平滑半宽（距离域，典型 0.04~0.12）
//   inactiveColor 未激活颜色（straight RGBA）
//   activeColor   高亮颜色（straight RGBA）
struct SubtitleUniforms {
    float2 viewportSize;
    float  progress;
    float  sdfSmoothing;
    float4 inactiveColor;
    float4 activeColor;
};

// 顶点到片段的插值输出。
struct SubtitleVaryings {
    float4 position [[position]];
    float2 uv;
    float  wordIndex;
};

// MARK: 顶点着色器

vertex SubtitleVaryings subtitleVertex(
    uint vid [[vertex_id]],
    const device SubtitleVertex *vertices [[buffer(0)]],
    constant SubtitleUniforms &uniforms [[buffer(1)]])
{
    const device SubtitleVertex &v = vertices[vid];
    SubtitleVaryings out;

    // layer 像素坐标（y 向下，左上原点）→ Metal NDC（y 向上，中心原点）。
    float2 ndc = float2(
        v.position.x / uniforms.viewportSize.x * 2.0 - 1.0,
        1.0 - v.position.y / uniforms.viewportSize.y * 2.0);
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = v.uv;
    out.wordIndex = v.wordIndex;
    return out;
}

// MARK: 片段着色器

fragment float4 subtitleFragment(
    SubtitleVaryings in [[stage_in]],
    texture2d<float, access::sample> sdfAtlas [[texture(0)]],
    constant SubtitleUniforms &uniforms [[buffer(1)]])
{
    constexpr sampler sdfSampler(
        coord::normalized,
        filter::linear,          // SDF 双线性采样：距离场线性插值仍成立
        address::clamp_to_edge);

    // 1. SDF 抗锯齿：距离场 0.5 = 字形边缘；
    //    smoothstep 在 [0.5-w, 0.5+w] 区间做平滑阶跃，边缘半透明过渡
    //    与分辨率/缩放无关（矢量级抗锯齿，无 MSAA 开销）。
    float dist = sdfAtlas.sample(sdfSampler, in.uv).r;
    float w = uniforms.sdfSmoothing;
    float alpha = smoothstep(0.5 - w, 0.5 + w, dist);

    // 2. 词级进度高亮：clamp(progress - wordIndex, 0, 1)
    //    progress=3.4 时：词 0~2 → ≥1 截为 1（完成），词 3 → 0.4（过渡），
    //    词 ≥4 → ≤0 截为 0（未激活）。mix 在两色间做线性插值——
    //    相邻帧进度连续变化时颜色平滑过渡，杜绝生硬的阶梯式跳跃。
    float t = clamp(uniforms.progress - in.wordIndex, 0.0, 1.0);
    float4 color = mix(uniforms.inactiveColor, uniforms.activeColor, t);

    // 3. 预乘 alpha 输出：最终透明度 = SDF 覆盖率 × 颜色自身 alpha
    //   （未激活态的半透明 0.55 由此生效），配合管线
    //   (one, oneMinusSourceAlpha) 混合，与 WindowServer 对半透明
    //   CAMetalLayer 的合成一致。
    float outAlpha = alpha * color.a;
    return float4(color.rgb * outAlpha, outAlpha);
}
