import Foundation
import SherpaONNX

let modelDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : (NSHomeDirectory() as NSString).appendingPathComponent(
        "/Library/Application Support/WhisperASR/Models/sense-voice-zh-en-ja-ko-yue")

print("== sherpa-onnx load smoke ==")
print("version:", String(cString: SherpaOnnxGetVersionStr()))
print("onnxruntime:", String(cString: SherpaOnnxGetOnnxruntimeVersionStr()))

let modelPath = strdup((modelDir as NSString).appendingPathComponent("model.int8.onnx"))
let tokensPath = strdup((modelDir as NSString).appendingPathComponent("tokens.txt"))
let provider = strdup("cpu")
defer { free(modelPath); free(tokensPath); free(provider) }

var config = SherpaOnnxOfflineRecognizerConfig()
config.model_config.sense_voice.model = UnsafePointer(modelPath)
config.model_config.sense_voice.use_itn = 1
config.model_config.tokens = UnsafePointer(tokensPath)
config.model_config.num_threads = 2
config.model_config.provider = UnsafePointer(provider)
config.model_config.debug = 0

guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
    // 非 Optional 约定下无法判空——到这说明编译期；运行时 NULL 用原始指针判：
    print("create returned null")
    exit(2)
}
print("recognizer created ✓")

// 推理冒烟：2 秒 440Hz 正弦（非静音，应有音频路径执行）+ decode
let stream = SherpaOnnxCreateOfflineStream(recognizer)
var samples = [Float](repeating: 0, count: 32000)
for i in 0..<samples.count {
    samples[i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 16000)
}
samples.withUnsafeBufferPointer { buf in
    SherpaOnnxAcceptWaveformOffline(stream, 16000, buf.baseAddress, Int32(buf.count))
}
SherpaOnnxDecodeOfflineStream(recognizer, stream)
if let result = SherpaOnnxGetOfflineStreamResult(stream) {
    let text = result.pointee.text.map { String(cString: $0) } ?? ""
    print("inference done ✓  text(\(text.count)):", text.isEmpty ? "(空——纯音调无语音,正常)" : text)
    SherpaOnnxDestroyOfflineRecognizerResult(result)
}
SherpaOnnxDestroyOfflineStream(stream)
SherpaOnnxDestroyOfflineRecognizer(recognizer)
print("SMOKE PASS")
