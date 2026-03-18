import Foundation
import AVFoundation
import Observation

@Observable
class AudioPlayerManager {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isLoaded = false
    var playbackRate: Float = 1.0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private(set) var currentURL: URL?

    func load(url: URL) {
        // Skip if already loaded
        if currentURL == url { return }
        cleanup()
        currentURL = url

        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        // Periodic time observer (~20 fps for smooth slider + highlighting)
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if !seconds.isNaN {
                self.currentTime = seconds
            }
        }

        // Duration
        Task { @MainActor [weak self] in
            guard let self, let asset = self.player?.currentItem?.asset else { return }
            if let dur = try? await asset.load(.duration) {
                let secs = dur.seconds
                self.duration = secs.isNaN ? 0 : secs
                self.isLoaded = true
            }
        }

        // End-of-playback
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
            self?.currentTime = 0
            self?.player?.seek(to: .zero)
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.rate = playbackRate
        }
        isPlaying.toggle()
    }

    func play() {
        guard let player, !isPlaying else { return }
        player.rate = playbackRate
        isPlaying = true
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    func pause() {
        guard let player, isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero,
                     toleranceAfter: .zero)
        currentTime = clamped
    }

    func skipForward(_ seconds: TimeInterval = 5) {
        seek(to: currentTime + seconds)
    }

    func skipBackward(_ seconds: TimeInterval = 5) {
        seek(to: currentTime - seconds)
    }

    func cleanup() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        if let endObs = endObserver {
            NotificationCenter.default.removeObserver(endObs)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoaded = false
        currentURL = nil
    }
}
