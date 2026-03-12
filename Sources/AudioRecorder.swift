import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import os

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

    private var stream: SCStream?
    private var samplesLock = OSAllocatedUnfairLock(initialState: [Float]())
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var recordingAppName: String?

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
                config.sampleRate = 16000
                // Minimal video config (required but we don't need video)
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

                samplesLock.withLock { $0.removeAll() }

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
        }

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        let samples = samplesLock.withLock { Array($0) }
        guard !samples.isEmpty else {
            await MainActor.run {
                state = .ready
                error = "No audio captured"
            }
            return nil
        }

        let url = writeWAV(samples: samples, sampleRate: 16000)

        await MainActor.run {
            state = .idle
            selectedApp = nil
        }

        return url
    }

    // MARK: - Cancel Recording

    func cancelRecording() {
        Task {
            if let stream {
                try? await stream.stopCapture()
                self.stream = nil
            }
            samplesLock.withLock { $0.removeAll() }

            await MainActor.run {
                state = .ready
                timer?.invalidate()
                timer = nil
                recordingDuration = 0
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let sampleCount = length / MemoryLayout<Float>.size / channelCount

        let floatPointer = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount * channelCount)

        var monoSamples: [Float]
        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: floatPointer, count: sampleCount))
        } else {
            // Mix to mono
            monoSamples = [Float](repeating: 0, count: sampleCount)
            for i in 0..<sampleCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += floatPointer[i * channelCount + ch]
                }
                monoSamples[i] = sum / Float(channelCount)
            }
        }

        let captured = monoSamples
        samplesLock.withLock { $0.append(contentsOf: captured) }
    }

    // MARK: - WAV Writing

    private func writeWAV(samples: [Float], sampleRate: Int) -> URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let recordingsDir = appSupport.appendingPathComponent("WhisperASR/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let appName = (recordingAppName ?? "Unknown")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let fileName = "\(appName)_\(timestamp).wav"
        let fileURL = recordingsDir.appendingPathComponent(fileName)

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 32
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let fileSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.appendLittleEndian(fileSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendLittleEndian(UInt32(16))          // chunk size
        header.appendLittleEndian(UInt16(3))            // IEEE float
        header.appendLittleEndian(numChannels)
        header.appendLittleEndian(UInt32(sampleRate))
        header.appendLittleEndian(byteRate)
        header.appendLittleEndian(blockAlign)
        header.appendLittleEndian(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendLittleEndian(dataSize)

        let sampleData = samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer.withMemoryRebound(to: UInt8.self) { $0 })
        }

        var fileData = header
        fileData.append(sampleData)

        do {
            try fileData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - System Preferences

    func openSystemPreferences() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
