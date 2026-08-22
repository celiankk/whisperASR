import Foundation
import SherpaONNX

let modelDir = (NSHomeDirectory() as NSString).appendingPathComponent(
    "/Library/Application Support/WhisperASR/Models/streaming-paraformer-bilingual-zh-en")
print("== paraformer-streaming smoke ==")
print("version:", String(cString: SherpaOnnxGetVersionStr()))

var owned: [UnsafeMutablePointer<CChar>] = []
let provider = strdup("cpu"); owned.append(provider!)
let encoder = strdup((modelDir as NSString).appendingPathComponent("encoder.int8.onnx")); owned.append(encoder!)
let decoder = strdup((modelDir as NSString).appendingPathComponent("decoder.int8.onnx")); owned.append(decoder!)
let tokens = strdup((modelDir as NSString).appendingPathComponent("tokens.txt")); owned.append(tokens!)
defer { owned.forEach { $0.deallocate() } }

var config = SherpaOnnxOnlineRecognizerConfig()
config.model_config.num_threads = 2
config.model_config.provider = UnsafePointer(provider)
config.model_config.paraformer.encoder = UnsafePointer(encoder)
config.model_config.paraformer.decoder = UnsafePointer(decoder)
config.model_config.tokens = UnsafePointer(tokens)
config.enable_endpoint = 1
config.rule2_min_trailing_silence = 1.2
config.rule3_min_utterance_length = 20

let recognizer = SherpaOnnxCreateOnlineRecognizer(&config)
print("online recognizer created ✓")
let stream = SherpaOnnxCreateOnlineStream(recognizer)

func feed(_ samples: [Float], label: String) {
    samples.withUnsafeBufferPointer { buf in
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, buf.baseAddress, Int32(buf.count))
    }
    while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
        SherpaOnnxDecodeOnlineStream(recognizer, stream)
    }
    if let r = SherpaOnnxGetOnlineStreamResult(recognizer, stream) {
        let text = r.pointee.text.map { String(cString: $0) } ?? ""
        SherpaOnnxDestroyOnlineRecognizerResult(r)
        print("[\(label)] text(\(text.count)):", text.isEmpty ? "(空)" : text)
    }
    let endpoint = SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream)
    print("[\(label)] endpoint=\(endpoint)")
    if endpoint == 1 {
        SherpaOnnxOnlineStreamReset(recognizer, stream)
        print("[\(label)] stream reset ✓")
    }
}

// 轮1：1s 440Hz（模拟语音起段）
var tone = [Float](repeating: 0, count: 16000)
for i in 0..<tone.count { tone[i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 16000) }
feed(tone, label: "1s-tone")
// 轮2：再 1s 440Hz（增量喂入——验证状态保持）
feed(tone, label: "2nd-tone")
// 轮3：1.5s 静音（触发端点）
feed([Float](repeating: 0, count: 24000), label: "silence")
// 轮4：reset 后再喂音（验证新段）
feed(tone, label: "post-reset-tone")

SherpaOnnxDestroyOnlineStream(stream)
SherpaOnnxDestroyOnlineRecognizer(recognizer)
print("STREAM SMOKE PASS")
