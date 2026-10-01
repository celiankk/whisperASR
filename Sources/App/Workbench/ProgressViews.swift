import SwiftUI

/// 环形进度（方案 8）：未知态呼吸 + 旋转，确定态描边推进。
///
/// 用同一条 stroke 做端点呼吸（不切换两套视图），避免状态翻转时尺寸跳动；
/// 呼吸循环只存在于未知态子视图里——确定态静止推进，不让整条列表都在动。
struct CircularProgressView: View {
    /// 0 视为未知态（排队/无进度），>0 为确定态。
    let progress: Double
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Ink.subtle, style: StrokeStyle(lineWidth: lineWidth))

            if progress > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.anim(Motion.standard(0.3)), value: progress)
            } else {
                UnknownRing(lineWidth: lineWidth)
            }
        }
    }
}

/// 未知态：旋转 + trim 端点呼吸（0.06 ↔ 0.30）。
private struct UnknownRing: View {
    var lineWidth: CGFloat = 1.5
    @State private var spin = false
    @State private var grow = false

    var body: some View {
        Circle()
            .trim(from: grow ? 0.30 : 0.06, to: grow ? 0.36 : 0.36)
            .stroke(Color.accentColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(spin ? 270 : -90))
            .onAppear {
                guard !MotionPrefs.shared.reduceMotion else { return }
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                    spin = true
                }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    grow = true
                }
            }
    }
}

/// 线性进度（转录中 / 模型下载共用）：细轨道 + tint 填充 + 数字滚动。
struct LinearProgressBar: View {
    let progress: Double
    var showsValue: Bool = false
    var tint: Color = Color.accentColor

    var body: some View {
        HStack(spacing: Metrics.md) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Ink.subtle)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(max(progress, 0), 1))))
                        .animation(Motion.anim(Motion.standard(0.3)), value: progress)
                }
            }
            .frame(height: 3)

            if showsValue {
                Text("\(Int(progress * 100))")
                    .font(Type.mono(Type.label, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.anim(Motion.standard(0.25)), value: progress)
                    .frame(width: 26, alignment: .trailing)
            }
        }
    }
}
