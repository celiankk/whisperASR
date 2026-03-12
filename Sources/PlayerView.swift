import SwiftUI

struct PlayerView: View {
    @Environment(AudioPlayerManager.self) var audioPlayer

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
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
        .background(.bar)
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
