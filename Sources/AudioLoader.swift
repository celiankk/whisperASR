import AVFoundation

enum AudioLoader {
    /// Load any audio/video file as 16 kHz mono PCM Float32 samples.
    static func loadSamples(url: URL) async throws -> [Float] {
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError.processFailed("No audio track found in file")
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)

        guard reader.startReading() else {
            throw reader.error ?? TranscriptionError.processFailed("Failed to start reading audio")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            _ = data.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: ptr.baseAddress!)
            }
            let floatCount = length / MemoryLayout<Float>.size
            data.withUnsafeBytes { ptr in
                let buf = UnsafeBufferPointer(
                    start: ptr.baseAddress!.assumingMemoryBound(to: Float.self),
                    count: floatCount
                )
                samples.append(contentsOf: buf)
            }
        }

        guard !samples.isEmpty else {
            throw TranscriptionError.processFailed("Audio file produced no samples")
        }

        return samples
    }
}
