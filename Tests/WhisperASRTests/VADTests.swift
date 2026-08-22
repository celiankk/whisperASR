import XCTest
@testable import WhisperASR

/// VAD 联合判定（RMS + 过零率）回归：
/// 干净输入与纯 RMS 判定一致；高频噪声（能量中等但过零率高）判非语音。
final class VADTests: XCTestCase {

    /// 生成正弦波（指定频率比例 = 过零密度的代理）。
    private func sine(samples: Int, amplitude: Float, crossingsPerSample: Float) -> [Float] {
        var result = [Float](repeating: 0, count: samples)
        let phase: Double = Double(crossingsPerSample) * Double.pi   // 每采样相位增量
        for i in 0..<samples {
            let value = Double(amplitude) * sin(phase * Double(i))
            result[i] = Float(value)
        }
        return result
    }

    func testPureSilenceIsNonSpeech() {
        let zeros = [Float](repeating: 0, count: 1600)
        let rms = VAD.rmsEnergy(zeros[...])
        let zcr = VAD.zeroCrossingRate(zeros[...])
        XCTAssertTrue(VAD.isNonSpeech(rms: rms, zcr: zcr, silenceThreshold: 0.001),
                      "纯静音（零信号）必须判非语音")
    }

    func testVoiceLikeSignalIsSpeech() {
        // 200Hz @16kHz：每采样约 0.025 次过零（每周期 2 次）。
        let voice = sine(samples: 1600, amplitude: 0.1, crossingsPerSample: 0.025)
        let rms = VAD.rmsEnergy(voice[...])
        let zcr = VAD.zeroCrossingRate(voice[...])
        XCTAssertGreaterThan(rms, 0.001, "人声幅度 RMS 应高于静音阈值")
        XCTAssertLessThan(zcr, VAD.zcrCeiling, "人声过零率应在语音带内")
        XCTAssertFalse(VAD.isNonSpeech(rms: rms, zcr: zcr, silenceThreshold: 0.001))
        XCTAssertTrue(VAD.isSpeech(rms: rms, zcr: zcr, speechThreshold: 0.005))
    }

    func testHighFrequencyNoiseIsNonSpeechDespiteEnergy() {
        // 5kHz @16kHz：每采样 0.625 次过零 → ZCR 远超上限。
        let hiss = sine(samples: 1600, amplitude: 0.05, crossingsPerSample: 0.625)
        let rms = VAD.rmsEnergy(hiss[...])
        let zcr = VAD.zeroCrossingRate(hiss[...])
        XCTAssertGreaterThan(rms, 0.001, "噪声能量高于静音阈值（纯 RMS 会误判为语音）")
        XCTAssertGreaterThan(zcr, VAD.zcrCeiling)
        XCTAssertTrue(VAD.isNonSpeech(rms: rms, zcr: zcr, silenceThreshold: 0.001),
                      "高频噪声（能量够但过零率超限）应判非语音")
        XCTAssertFalse(VAD.isSpeech(rms: rms, zcr: zcr, speechThreshold: 0.001))
    }

    func testMusicLikeSignalStaysSpeech() {
        // 音乐主体（基频稳定低过零率）不得被误判为静音（唱歌字幕场景）。
        // 440Hz @16kHz：每采样 0.055 次过零。
        let music = sine(samples: 1600, amplitude: 0.08, crossingsPerSample: 0.055)
        let rms = VAD.rmsEnergy(music[...])
        let zcr = VAD.zeroCrossingRate(music[...])
        XCTAssertTrue(VAD.isSpeech(rms: rms, zcr: zcr, speechThreshold: 0.005),
                      "低过零率音乐信号应保持语音判定（不误伤唱歌字幕）")
    }

    func testZCRBoundary() {
        // 常数信号无过零；交替符号信号 N 样本 N-1 次翻转（首样本无前序）。
        XCTAssertEqual(VAD.zeroCrossingRate([Float](repeating: 0.5, count: 100)[...]), 0)
        let alternating = (0..<100).map { Float($0 % 2 == 0 ? 1 : -1) }
        XCTAssertEqual(VAD.zeroCrossingRate(alternating[...]), 0.99, accuracy: 0.001)
    }
}
