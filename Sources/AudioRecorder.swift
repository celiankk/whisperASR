import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import os
import CoreGraphics
import UserNotifications

enum RecordingState: Equatable {
    case idle
    case loading
    case ready
    case recording
    case saving
    case permissionDenied
}

@Observable
class AudioRecorder: NSObject, SCStreamOutput {
    var state: RecordingState = .idle
    var availableApps: [SCRunningApplication] = []
    var selectedApp: SCRunningApplication?
    var recordingDuration: TimeInterval = 0
    var error: String?
    var meetingEnded = false

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingAppName: String?
    private var outputURL: URL?
    private var _hasReceivedSamples = OSAllocatedUnfairLock(initialState: false)
    private var meetingMonitorTimer: Timer?
    private var recordingPID: pid_t?
    private var hadMeetingWindow = false

    private static let zoomBundleIDs: Set<String> = ["us.zoom.xos", "us.zoom.videomeeting"]

    // MARK: - App List

    func loadAvailableApps() {
        state = .loading
        error = nil

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let myBundleID = Bundle.main.bundleIdentifier ?? "com.whisperasr"
                let apps = content.applications
                    .filter { $0.bundleIdentifier != myBundleID }
                    .sorted { ($0.applicationName) < ($1.applicationName) }

                await MainActor.run {
                    self.availableApps = apps
                    self.state = .ready
                }
            } catch {
                await MainActor.run {
                    if (error as NSError).code == -3801 || "\(error)".contains("denied") {
                        self.state = .permissionDenied
                    } else {
                        self.error = error.localizedDescription
                        self.state = .permissionDenied
                    }
                }
            }
        }
    }

    // MARK: - Start Recording

    func startRecording(app: SCRunningApplication) {
        guard state == .ready else { return }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    await MainActor.run {
                        self.error = "No display found"
                    }
                    return
                }

                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.channelCount = 1
                config.sampleRate = 48000
                // Minimal video config (required but we don't need video)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                let fileURL = self.makeOutputURL(appName: app.applicationName)
                // Remove any existing file at this path
                try? FileManager.default.removeItem(at: fileURL)

                let writer = try AVAssetWriter(outputURL: fileURL, fileType: .m4a)
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)

                self.assetWriter = writer
                self.assetWriterInput = input
                self.outputURL = fileURL
                self._hasReceivedSamples.withLock { $0 = false }

                let stream = SCStream(filter: filter, configuration: config, delegate: nil)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.whisperasr.audio-capture"))
                try await stream.startCapture()

                self.stream = stream
                self.recordingAppName = app.applicationName

                await MainActor.run {
                    self.state = .recording
                    self.recordingDuration = 0
                    self.recordingStartTime = Date()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        guard let self, let start = self.recordingStartTime else { return }
                        self.recordingDuration = Date().timeIntervalSince(start)
                    }
                    self.startMeetingMonitor(app: app)
                }
            } catch {
                await MainActor.run {
                    self.error = "Failed to start recording: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Stop Recording

    func stopRecording() async -> URL? {
        await MainActor.run {
            state = .saving
            timer?.invalidate()
            timer = nil
            stopMeetingMonitor()
        }

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        let received = _hasReceivedSamples.withLock { $0 }
        print("[AudioRecorder] stopRecording: hasReceivedSamples=\(received), writer=\(assetWriter != nil), input=\(assetWriterInput != nil)")

        guard let writer = assetWriter, let input = assetWriterInput else {
            assetWriter = nil
            assetWriterInput = nil
            if let url = outputURL {
                try? FileManager.default.removeItem(at: url)
            }
            print("[AudioRecorder] stopRecording: no writer/input, returning nil")
            return nil
        }

        input.markAsFinished()
        await writer.finishWriting()

        print("[AudioRecorder] stopRecording: writer.status=\(writer.status.rawValue), error=\(String(describing: writer.error))")

        let url: URL?
        if writer.status == .completed, received {
            url = outputURL
        } else {
            url = nil
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        assetWriter = nil
        assetWriterInput = nil

        print("[AudioRecorder] stopRecording: returning url=\(String(describing: url))")
        return url
    }

    // MARK: - Cancel Recording

    func cancelRecording() {
        Task {
            if let stream {
                try? await stream.stopCapture()
                self.stream = nil
            }

            if let writer = assetWriter {
                writer.cancelWriting()
                if let url = outputURL {
                    try? FileManager.default.removeItem(at: url)
                }
                assetWriter = nil
                assetWriterInput = nil
            }

            await MainActor.run {
                state = .ready
                timer?.invalidate()
                timer = nil
                stopMeetingMonitor()
                recordingDuration = 0
            }
        }
    }

    // MARK: - Zoom Meeting Monitor

    private func startMeetingMonitor(app: SCRunningApplication) {
        guard Self.zoomBundleIDs.contains(app.bundleIdentifier) else { return }
        recordingPID = app.processID
        hadMeetingWindow = false
        meetingEnded = false

        meetingMonitorTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.checkZoomMeetingWindows()
        }
    }

    private func stopMeetingMonitor() {
        meetingMonitorTimer?.invalidate()
        meetingMonitorTimer = nil
        recordingPID = nil
        hadMeetingWindow = false
    }

    private func checkZoomMeetingWindows() {
        guard let pid = recordingPID else { return }

        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        let hasMeeting = windowList.contains { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { return false }

            // Check for meeting-sized windows (not tiny overlays or toolbars)
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let width = bounds["Width"], let height = bounds["Height"],
               width >= 300, height >= 200 {
                // Check window name for meeting indicators
                let name = info[kCGWindowName as String] as? String ?? ""
                // Zoom meeting windows: "Zoom Meeting", meeting topic, or large unnamed windows
                if name.localizedCaseInsensitiveContains("meeting") ||
                   name.localizedCaseInsensitiveContains("zoom") ||
                   name.isEmpty {
                    return true
                }
            }
            return false
        }

        if hasMeeting {
            hadMeetingWindow = true
        } else if hadMeetingWindow {
            // Meeting window was present but now gone — meeting ended
            meetingMonitorTimer?.invalidate()
            meetingMonitorTimer = nil
            meetingEnded = true
            sendMeetingEndedNotification()
        }
    }

    private func sendMeetingEndedNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Zoom Meeting Ended"
            content.body = "The Zoom meeting has ended. Would you like to stop recording?"
            content.sound = .default

            let request = UNNotificationRequest(identifier: "zoom-meeting-ended", content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let input = assetWriterInput else {
            print("[AudioRecorder] stream callback: no assetWriterInput")
            return
        }
        guard input.isReadyForMoreMediaData else {
            print("[AudioRecorder] stream callback: input not ready")
            return
        }

        let success = input.append(sampleBuffer)
        if success {
            let wasFirst = _hasReceivedSamples.withLock { val -> Bool in
                let first = !val
                val = true
                return first
            }
            if wasFirst {
                print("[AudioRecorder] first audio sample appended, numSamples=\(sampleBuffer.numSamples)")
            }
        } else {
            print("[AudioRecorder] stream callback: append failed, writer.status=\(assetWriter?.status.rawValue ?? -1), error=\(String(describing: assetWriter?.error))")
        }
    }

    // MARK: - Output URL

    private func makeOutputURL(appName: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("WhisperASR/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd HH'h'"
        let timestamp = df.string(from: Date())
        let sanitized = appName
            .replacingOccurrences(of: "/", with: "-")
        return recordingsDir.appendingPathComponent("\(timestamp) \(sanitized).m4a")
    }

    // MARK: - System Preferences

    func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
