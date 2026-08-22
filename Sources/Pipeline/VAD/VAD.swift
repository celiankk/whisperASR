import Foundation

// MARK: - 语音活动检测（VAD）— 管线环节 2
//
// 能量（RMS）+ 频域代理特征（过零率 ZCR）联合判定：
// - 主判据仍为 RMS（与原自适应噪声底阈值体系完全兼容——干净输入下
//   行为不变，保证既有断句手感不回退）；
// - ZCR 上限补充：中等能量但过零率极高的帧（高频嘶声 / 电流噪 /
//   风噪）判为非语音——纯能量判定会把这类稳态噪声当语音，
//   导致封口失效、每轮重转录长尾（噪声场景延迟劣化）；
// - 人声（浊音+清音混合）帧级 ZCR 远低于白噪/嘶声，音乐主体也低
//   ZCR（基频稳定），不会被误判为静音（不伤唱歌字幕场景）。
//
// 接入点：AudioRecorder.lastSilenceCut（封口判定）、
// AppleSpeechManager.hasTrailingSilence（断句点检测）。

enum VAD {
    /// 过零率上限（0–1）：帧内采样符号翻转比例超过该值视为非语音噪声。
    /// 人声帧级 ZCR 典型 < 0.2；白噪 ≈ 0.5；高频嘶声 > 0.35。
    static let zcrCeiling: Float = 0.35

    /// 帧过零率（符号翻转数 / 采样数）。
    static func zeroCrossingRate(_ frame: ArraySlice<Float>) -> Float {
        var crossings: Int = 0
        var previous: Float = 0
        var started = false
        for sample in frame {
            let sign: Float = sample >= 0 ? 1 : -1
            if started, sign != previous {
                crossings += 1
            }
            previous = sign
            started = true
        }
        let count = max(1, frame.count)
        return Float(crossings) / Float(count)
    }

    /// 帧 RMS 能量。
    static func rmsEnergy(_ frame: ArraySlice<Float>) -> Float {
        var sumSquares: Float = 0
        var count: Int = 0
        for sample in frame {
            sumSquares += sample * sample
            count += 1
        }
        guard count > 0 else { return 0 }
        return (sumSquares / Float(count)).squareRoot()
    }

    /// 帧是否为「非语音」（静音判定）：
    /// 能量低于阈值（原语义），或能量够但过零率超上限（高频噪声）。
    /// 干净麦克风输入下与纯 RMS 判定完全一致（底噪 RMS 远低于阈值）。
    static func isNonSpeech(rms: Float, zcr: Float, silenceThreshold: Float) -> Bool {
        if rms < silenceThreshold { return true }
        return zcr > zcrCeiling
    }

    /// 帧是否为「语音」：非静音且非高频噪声（能量在语音带 + ZCR 在人声带）。
    static func isSpeech(rms: Float, zcr: Float, speechThreshold: Float) -> Bool {
        guard rms >= speechThreshold else { return false }
        return zcr <= zcrCeiling
    }
}
