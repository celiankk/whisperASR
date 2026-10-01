import SwiftUI

/// 悬浮播放胶囊（方向 A）：浮在右栏底部中央，取代原底部常驻播放条。
///
/// 形态：空闲=mini 胶囊（仅播放键+当前时间），播放中/悬停=展开（进度轨+前后跳+倍速）。
/// 材质：`.regularMaterial` + 0.5px 发丝环 + 站点浮层阴影栈；小面积实时模糊，
/// 不参与列表滚动，性能开销可控（大面积实时模糊是掉帧元凶，这里刻意避开）。
struct PlayerCapsule: View {
    @Environment(AudioPlayerManager.self) var audioPlayer
    @State private var showSpeed = false
    @State private var hovering = false

    private var expanded: Bool {
        audioPlayer.isPlaying || hovering || showSpeed
    }

    private var duration: Double { max(audioPlayer.duration, 0.01) }

    var body: some View {
        HStack(spacing: Metrics.md) {
            Text(formatTime(audioPlayer.currentTime))
                .font(Type.mono(Type.micro, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 44, alignment: .trailing)

            if expanded {
                SeekTrack(ratio: min(audioPlayer.currentTime / duration, 1)) { newRatio in
                    audioPlayer.seek(to: newRatio * duration)
                }
                .frame(width: 180)

                SkipButton(symbol: "gobackward.5") { audioPlayer.skipBackward(5) }
            }

            playButton

            if expanded {
                SkipButton(symbol: "goforward.5") { audioPlayer.skipForward(5) }

                Text(formatTime(audioPlayer.duration))
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 44)

                RateChip(showSpeed: $showSpeed, audioPlayer: audioPlayer)
            }
        }
        .padding(.horizontal, expanded ? 14 : 8)
        .frame(height: 38)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 2.5, y: 2)
        .shadow(color: .black.opacity(0.10), radius: 14, y: 10)
        .onHover { hovering = $0 }
        .animation(Motion.anim(Motion.exit(0.3)), value: expanded)
        .padding(.bottom, 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放器")
    }

    private var playButton: some View {
        Button(action: { audioPlayer.togglePlayPause() }) {
            Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.primary.opacity(0.85))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help("播放 / 暂停（空格）")
        // 录制中的红点脉冲留在浮层，这里只做静音式的深色符号。
        .animation(Motion.anim(Motion.standard(0.18)), value: audioPlayer.isPlaying)
    }
}

private struct SkipButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.secondary)
        }
        .buttonStyle(GhostButtonStyle(size: 24))
    }
}

/// 进度轨：点/拖即 seek（操作落在内容本身，不再放一个独立滑块）。
private struct SeekTrack: View {
    let ratio: Double
    let onSeek: (Double) -> Void
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shown = dragging ? dragRatio : ratio
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.active).frame(height: 3)
                Capsule()
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: w * CGFloat(min(max(shown, 0), 1)), height: 3)
                Circle()
                    .fill(Color.primary)
                    .frame(width: hovering || dragging ? 9 : 0)
                    .offset(x: w * CGFloat(min(max(shown, 0), 1)) - (hovering || dragging ? 4.5 : 0))
                    .animation(Motion.anim(Motion.standard(0.15)), value: hovering || dragging)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        dragRatio = clampRatio(value.location.x / w)
                    }
                    .onEnded { value in
                        onSeek(clampRatio(value.location.x / w))
                        dragging = false
                    }
            )
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
    }

    @State private var dragRatio: Double = 0

    private func clampRatio(_ r: CGFloat) -> Double {
        Double(min(max(r, 0), 1))
    }
}

/// 倍速 chip + 弹层。
private struct RateChip: View {
    @Binding var showSpeed: Bool
    @Bindable var audioPlayer: AudioPlayerManager

    var body: some View {
        Button {
            showSpeed.toggle()
        } label: {
            Text(formatRate(audioPlayer.playbackRate))
                .font(Type.mono(Type.micro, weight: .medium))
                .chipStyle(selected: audioPlayer.playbackRate != 1.0)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSpeed, arrowEdge: .bottom) {
            SpeedControlPopover(audioPlayer: audioPlayer)
        }
        .help("播放倍速")
    }

    private func formatRate(_ rate: Float) -> String {
        rate == Float(Int(rate)) ? String(format: "%.0fx", rate) : String(format: "%.2gx", rate)
    }
}

extension PlayerCapsule {
    func formatTime(_ seconds: TimeInterval) -> String {
        guard !seconds.isNaN && seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - 倍速弹层

/// 弹层里的预设走胶囊轨道（方案 4）：横向可滚 + 两端渐隐 + soft 选中态。
struct SpeedControlPopover: View {
    @Bindable var audioPlayer: AudioPlayerManager
    @State private var sliderRate: Float = 1.0
    @State private var isDragging = false
    private let presets: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    private let minRate: Float = 0.25
    private let maxRate: Float = 3.0
    private let step: Float = 0.05

    private var displayRate: Float {
        isDragging ? sliderRate : audioPlayer.playbackRate
    }

    var body: some View {
        VStack(spacing: Metrics.lg) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.2f", displayRate))
                    .font(Type.mono(Type.display, weight: .medium))
                    .contentTransition(.numericText())
                Text("×")
                    .font(Type.mono(Type.label))
                    .foregroundStyle(Ink.secondary)
            }
            .animation(Motion.anim(Motion.standard(0.2)), value: displayRate)

            HStack(spacing: Metrics.md) {
                Button { adjustRate(by: -step) } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle(size: 24))

                Slider(value: $sliderRate, in: minRate...maxRate, step: step) {
                    EmptyView()
                } onEditingChanged: { editing in
                    isDragging = editing
                    if !editing { audioPlayer.setRate(sliderRate) }
                }
                .controlSize(.small)

                Button { adjustRate(by: step) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(GhostButtonStyle(size: 24))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.xs) {
                    ForEach(presets, id: \.self) { rate in
                        Button {
                            sliderRate = rate
                            audioPlayer.setRate(rate)
                        } label: {
                            Text(formatPreset(rate))
                        }
                        .buttonStyle(.plain)
                        .chipStyle(selected: audioPlayer.playbackRate == rate)
                    }
                }
                .padding(.horizontal, 2)
            }
            .edgeFadeHorizontal(20)
        }
        .padding(Metrics.xl)
        .frame(width: 260)
        .onAppear { sliderRate = audioPlayer.playbackRate }
    }

    private func adjustRate(by delta: Float) {
        let newRate = min(maxRate, max(minRate, audioPlayer.playbackRate + delta))
        let snapped = (newRate * 20).rounded() / 20
        sliderRate = snapped
        audioPlayer.setRate(snapped)
    }

    private func formatPreset(_ rate: Float) -> String {
        rate == Float(Int(rate)) ? String(format: "%.0f", rate) : String(format: "%.2g", rate)
    }
}
