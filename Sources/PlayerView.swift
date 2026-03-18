import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerManager.self) var audioPlayer
    @State private var showSpeedPopover = false

    var body: some View {
        VStack(spacing: 4) {
            // Progress slider
            Slider(
                value: Binding(
                    get: { audioPlayer.currentTime },
                    set: { audioPlayer.seek(to: $0) }
                ),
                in: 0...max(audioPlayer.duration, 0.01)
            )
            .controlSize(.small)
            .padding(.horizontal, 16)

            HStack(spacing: 20) {
                // Current time
                Text(formatTime(audioPlayer.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)

                Spacer()

                // Skip backward
                Button(action: { audioPlayer.skipBackward(5) }) {
                    Image(systemName: "gobackward.5")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                // Play / Pause
                Button(action: { audioPlayer.togglePlayPause() }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                // Skip forward
                Button(action: { audioPlayer.skipForward(5) }) {
                    Image(systemName: "goforward.5")
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Spacer()

                // Duration
                Text(formatTime(audioPlayer.duration))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)

                // Speed control
                Button {
                    showSpeedPopover.toggle()
                } label: {
                    Text(formatRate(audioPlayer.playbackRate))
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundStyle(audioPlayer.playbackRate != 1.0 ? .green : .secondary)
                        .frame(width: 38)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSpeedPopover, arrowEdge: .top) {
                    SpeedControlPopover(audioPlayer: audioPlayer)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func formatRate(_ rate: Float) -> String {
        rate == Float(Int(rate)) ? String(format: "%.0fx", rate) : String(format: "%.2gx", rate)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard !seconds.isNaN && seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Speed Control Popover

struct SpeedControlPopover: View {
    @Bindable var audioPlayer: AudioPlayerManager
    @State private var sliderRate: Float = 1.0
    @State private var isDragging = false
    private let presets: [Float] = [1.0, 1.2, 1.5, 2.0]
    private let minRate: Float = 0.25
    private let maxRate: Float = 3.0
    private let step: Float = 0.05

    private var displayRate: Float {
        isDragging ? sliderRate : audioPlayer.playbackRate
    }

    var body: some View {
        VStack(spacing: 12) {
            // Current speed display
            Text(String(format: "%.2fx", displayRate))
                .font(.system(.title2, design: .monospaced).bold())

            // Slider with +/- buttons
            HStack(spacing: 10) {
                Button {
                    adjustRate(by: -step)
                } label: {
                    Image(systemName: "minus")
                        .font(.body.bold())
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Slider(
                    value: $sliderRate,
                    in: minRate...maxRate,
                    step: step
                ) {
                    EmptyView()
                } onEditingChanged: { editing in
                    isDragging = editing
                    if !editing {
                        audioPlayer.setRate(sliderRate)
                    }
                }

                Button {
                    adjustRate(by: step)
                } label: {
                    Image(systemName: "plus")
                        .font(.body.bold())
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Preset chips
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { rate in
                    Button {
                        sliderRate = rate
                        audioPlayer.setRate(rate)
                    } label: {
                        Text(formatPreset(rate))
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(audioPlayer.playbackRate == rate ? Color.accentColor : Color.primary.opacity(0.1))
                            .foregroundStyle(audioPlayer.playbackRate == rate ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

        }
        .padding(16)
        .frame(width: 240)
        .onAppear {
            sliderRate = audioPlayer.playbackRate
        }
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
