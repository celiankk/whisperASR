import Foundation
import Observation

@Observable
final class ModelDownloader {
    enum State: Equatable {
        case prompt
        case downloading
        case completed
        case failed(String)
    }

    var state: State = .prompt
    var progress: Double = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var estimatedTimeRemaining: String?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var delegate: DownloadDelegate?
    private var downloadStartTime: Date?
    private var downloadStartBytes: Int64 = 0

    static let modelURL = URL(string: "https://huggingface.co/danielkao0421/Breeze-ASR-25-ggml/resolve/main/ggml-model.bin")!

    static var modelDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/Models")
    }

    static var modelPath: URL {
        modelDirectory.appendingPathComponent("ggml-model.bin")
    }

    private static var resumeDataURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("WhisperASR/.model-download-resume")
    }

    var hasResumeData: Bool {
        FileManager.default.fileExists(atPath: Self.resumeDataURL.path)
    }

    var progressText: String {
        let downloaded = String(format: "%.0f", Double(downloadedBytes) / 1_000_000)
        if totalBytes > 0 {
            let total = String(format: "%.0f", Double(totalBytes) / 1_000_000)
            return "\(downloaded) / \(total) MB"
        }
        return "\(downloaded) / ~3,000 MB"
    }

    func startDownload() {
        state = .downloading
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        estimatedTimeRemaining = nil
        downloadStartTime = Date()
        downloadStartBytes = 0

        let del = DownloadDelegate(downloader: self)
        self.delegate = del
        session = URLSession(configuration: .default, delegate: del, delegateQueue: nil)

        if let resumeData = try? Data(contentsOf: Self.resumeDataURL) {
            downloadTask = session?.downloadTask(withResumeData: resumeData)
            try? FileManager.default.removeItem(at: Self.resumeDataURL)
        } else {
            downloadTask = session?.downloadTask(with: Self.modelURL)
        }

        downloadTask?.resume()
    }

    func cancelDownload() {
        state = .prompt
        downloadTask?.cancel(byProducingResumeData: { _ in
            // Resume data is saved in didCompleteWithError delegate
        })
    }

    fileprivate func handleDownloadFinished(location: URL) {
        do {
            try FileManager.default.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
            let dest = Self.modelPath
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            try? FileManager.default.removeItem(at: Self.resumeDataURL)
            DispatchQueue.main.async {
                self.state = .completed
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .failed("Failed to save model: \(error.localizedDescription)")
            }
        }
    }

    fileprivate func handleProgress(totalBytesWritten: Int64, totalBytesExpected: Int64) {
        DispatchQueue.main.async {
            self.downloadedBytes = totalBytesWritten
            self.totalBytes = totalBytesExpected
            if totalBytesExpected > 0 {
                self.progress = Double(totalBytesWritten) / Double(totalBytesExpected)
            }

            // Estimate time remaining based on average speed since download started
            if let startTime = self.downloadStartTime {
                let elapsed = Date().timeIntervalSince(startTime)
                let bytesDownloaded = totalBytesWritten - self.downloadStartBytes
                if elapsed > 2, bytesDownloaded > 0 {
                    let bytesPerSecond = Double(bytesDownloaded) / elapsed
                    let remainingBytes: Double
                    if totalBytesExpected > 0 {
                        remainingBytes = Double(totalBytesExpected - totalBytesWritten)
                    } else {
                        // Assume ~3 GB total if server doesn't report size
                        remainingBytes = max(0, 3_000_000_000 - Double(totalBytesWritten))
                    }
                    let secondsRemaining = remainingBytes / bytesPerSecond
                    self.estimatedTimeRemaining = self.formatTimeRemaining(secondsRemaining)
                }
            }
        }
    }

    private func formatTimeRemaining(_ seconds: Double) -> String {
        if seconds < 60 {
            return "Less than a minute remaining"
        } else if seconds < 3600 {
            let minutes = Int(ceil(seconds / 60))
            return "About \(minutes) min remaining"
        } else {
            let hours = Int(seconds / 3600)
            let minutes = Int(ceil((seconds - Double(hours * 3600)) / 60))
            return "About \(hours)h \(minutes)m remaining"
        }
    }

    fileprivate func handleError(_ error: Error) {
        // Save resume data if available
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? FileManager.default.createDirectory(
                at: Self.resumeDataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? resumeData.write(to: Self.resumeDataURL)
        }
        // Don't update state for user-initiated cancellation
        if (error as? URLError)?.code != .cancelled {
            DispatchQueue.main.async {
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var downloader: ModelDownloader?

    init(downloader: ModelDownloader) {
        self.downloader = downloader
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        downloader?.handleDownloadFinished(location: location)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloader?.handleProgress(totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            downloader?.handleError(error)
        }
    }
}
