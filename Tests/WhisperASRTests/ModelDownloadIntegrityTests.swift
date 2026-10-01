import XCTest
@testable import WhisperASR

// MARK: - 模型下载完整性判定回归（P0/P1）
//
// 背景两个真实故障：
// 1) `isComplete` 对 FunASR 硬编码查 `model.int8.onnx`，而 streaming-paraformer
//    （encoder/decoder）与 fun-asr-nano（encoder_adaptor/llm/embedding）
//    都没有这个文件 → 下载成功也永远无法选中；
// 2) 下载尺寸校验是**双向 1% 容差**，3.1GB 模型少 31MB 仍算完整，
//    随后被当成可用模型。

final class ModelDownloadIntegrityTests: XCTestCase {

    // MARK: 下载尺寸校验

    func testTruncatedDownloadIsRejected() {
        // 3.1GB 少 31MB（旧规则 1% 容差内 → 被接受）。
        let expected: Int64 = 3_100_000_000
        let actual = expected - 31_000_000
        XCTAssertTrue(ModelDownloader.shouldRejectDownload(actual: actual, expected: expected),
                      "截断下载必须拒绝（旧规则会接受）")
    }

    func testExactSizeIsAccepted() {
        XCTAssertFalse(ModelDownloader.shouldRejectDownload(actual: 1000, expected: 1000))
    }

    func testSmallOverageTolerated() {
        // CDN 附加少量内容 / expectedContentLength 为压缩前长度：不该误杀。
        XCTAssertFalse(ModelDownloader.shouldRejectDownload(actual: 1_005, expected: 1_000))
    }

    func testHugeOverageRejected() {
        XCTAssertTrue(ModelDownloader.shouldRejectDownload(actual: 2_000, expected: 1_000))
    }

    func testUnknownExpectedLengthIsNotRejected() {
        // expectedContentLength 缺失（chunked/重定向）：无法判定，不拦。
        XCTAssertFalse(ModelDownloader.shouldRejectDownload(actual: 123, expected: 0))
    }

    // MARK: FunASR 完整性清单

    func testFunASRConfigsDeclareRealModelFiles() {
        // 每个 FunASR 模型的首选清单必须与实际发布包一致（历史上 nano 的
        // tokenizer 被当成文件，上游要求目录）。
        let streaming = FunASRModelConfig.paraformerStreaming
        XCTAssertTrue(streaming.requiredFiles.contains("encoder.int8.onnx"))
        XCTAssertTrue(streaming.requiredFiles.contains("decoder.int8.onnx"))

        let nano = FunASRModelConfig.funASRNano
        XCTAssertTrue(nano.requiredFiles.contains("llm.int8.onnx"))
        XCTAssertTrue(nano.requiredFiles.contains("embedding.int8.onnx"))
        // nano 不吃 tokens.txt（sherpa-onnx 从 tokenizer 目录取词表）。
        XCTAssertFalse(nano.requiredFiles.contains("tokens.txt"),
                       "nano 不应要求 tokens.txt")

        let senseVoice = FunASRModelConfig.senseVoiceSmall
        XCTAssertTrue(senseVoice.requiredFiles.contains("model.int8.onnx"))
    }

    func testFunASRConfigResolvesAlternateLayouts() throws {
        // 新旧两版 nano 包的文件名/位置不同，resolve 必须都能命中。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("funasr-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func touch(_ relative: String) throws {
            let url = dir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }

        // 新版布局：encoder_adaptor + Qwen3-0.6B/ 目录（含 tokenizer 三件套）
        try touch("encoder_adaptor.int8.onnx")
        try touch("llm.int8.onnx")
        try touch("embedding.int8.onnx")
        try touch("Qwen3-0.6B/tokenizer.json")
        try touch("Qwen3-0.6B/vocab.json")
        try touch("Qwen3-0.6B/merges.txt")

        let config = FunASRModelConfig.funASRNano
        XCTAssertTrue(config.isComplete(in: dir),
                      "新版布局必须被识别为完整，缺失: \(config.missingDescription(in: dir))")
        let resolved = config.resolve(in: dir)
        XCTAssertEqual(resolved["encoder"], "encoder_adaptor.int8.onnx")
        XCTAssertEqual(resolved["tokenizer"], "Qwen3-0.6B",
                       "tokenizer 必须是目录（上游检查 <dir>/vocab.json 等）")
    }

    func testTokenizerDirectoryRequiresInnerFiles() throws {
        // 只有空的 tokenizer 目录 = 不完整（上游会因缺 vocab.json 加载失败）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("funasr-tok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func touch(_ relative: String) throws {
            let url = dir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try touch("encoder_adaptor.int8.onnx")
        try touch("llm.int8.onnx")
        try touch("embedding.int8.onnx")
        // tokenizer.json 直接摊在根目录：不是合法 tokenizer 目录。
        try touch("tokenizer.json")

        XCTAssertFalse(FunASRModelConfig.funASRNano.isComplete(in: dir),
                       "缺 vocab.json/merges.txt 的 tokenizer 应判为不完整")
    }
}
