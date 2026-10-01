import XCTest
import Observation
@testable import WhisperASR

// MARK: - 浮层双模型隔离单测（P1 渲染优化）
//
// 核心不变量：写入高频域（SubtitleStreamModel）不触发低频域
// （OverlayControlModel）的观察者，反之亦然——这是「字幕高频刷新时
// 控制栏零 Body Evaluation」的状态层根基。
// 追踪语义：withObservationTracking 的 onChange 只在**被读属性所属
// 对象**的对应属性写入时触发（@Observable 按对象+属性注册）。
final class OverlayStateIsolationTests: XCTestCase {

    /// 在隔离闭包里读取属性集合 → 写入探测值 → 等待观察者回调窗口
    /// → 断言 onChange 是否触发。
    private func expectChange(
        onWrite write: @escaping () -> Void,
        whenRead read: @escaping () -> Void,
        shouldFire: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectation = expectation(description: "observation onChange")
        expectation.isInverted = !shouldFire
        withObservationTracking {
            read()
        } onChange: {
            expectation.fulfill()
        }
        write()
        // Observation 回调异步派发：给运行循环几个空转窗口。
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        waitForExpectations(timeout: 0.5)
    }

    // MARK: 高频域 → 低频域隔离

    func testStreamWriteDoesNotFireControlObserver() {
        let vm = FloatingLetterViewModel()
        expectChange(
            onWrite: { vm.stream.subtitleText = "高频字幕更新" },
            whenRead: { _ = vm.controls.isPinned; _ = vm.controls.isCompact },
            shouldFire: false)
    }

    func testStreamRendererWriteDoesNotFireControlObserver() {
        let vm = FloatingLetterViewModel()
        expectChange(
            onWrite: { var r = vm.stream.renderer; r.setLines(["你好", "世界"]); vm.stream.renderer = r },
            whenRead: { _ = vm.controls.controlVisibility },
            shouldFire: false)
    }

    // MARK: 低频域 → 高频域隔离

    func testControlWriteDoesNotFireStreamObserver() {
        let vm = FloatingLetterViewModel()
        expectChange(
            onWrite: { vm.controls.isPinned.toggle() },
            whenRead: { _ = vm.stream.subtitleText; _ = vm.stream.renderer.text },
            shouldFire: false)
    }

    // MARK: 正向触发（确认追踪本身在工作，防止测试恒假）

    func testStreamWriteFiresStreamObserver() {
        let vm = FloatingLetterViewModel()
        expectChange(
            onWrite: { vm.stream.subtitleText = "变化" },
            whenRead: { _ = vm.stream.subtitleText },
            shouldFire: true)
    }

    func testControlWriteFiresControlObserver() {
        let vm = FloatingLetterViewModel()
        expectChange(
            onWrite: { vm.controls.isPinned.toggle() },
            whenRead: { _ = vm.controls.isPinned },
            shouldFire: true)
    }

    // MARK: 兼容委托层（@Observable 只追踪存储属性，委托不注册 VM 自身）

    func testCompatWriteDelegatesToModels() {
        let vm = FloatingLetterViewModel()
        vm.isPinned = true
        XCTAssertTrue(vm.controls.isPinned)
        vm.subtitleText = "经兼容层写入"
        XCTAssertEqual(vm.stream.subtitleText, "经兼容层写入")
        // 经兼容层读取时的追踪同样落在数据源上：写 stream 不触发
        // 「读 controls 委托属性」的观察者。
        expectChange(
            onWrite: { vm.stream.subtitleText = "再一次" },
            whenRead: { _ = vm.controls.isPinned; _ = vm.controls.isCompact },
            shouldFire: false)
    }

    // MARK: 派生显示

    func testDisplayedSubtitleTextReadsBothDomains() {
        let vm = FloatingLetterViewModel()
        vm.controls.translationOnly = true
        vm.stream.showingTranslation = true
        vm.stream.translationText = "  "   // 空白译文视为无译文
        vm.stream.recognitionText = "partial text"
        XCTAssertEqual(vm.displayedSubtitleText, "partial text")
        vm.stream.translationText = "完整译文"
        XCTAssertEqual(vm.displayedSubtitleText, "完整译文")
    }
}
