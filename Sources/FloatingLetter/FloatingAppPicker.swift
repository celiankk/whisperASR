import AppKit
import SwiftUI

// MARK: - 独立“选择应用”弹窗
//
// 与字幕浮层完全解耦：不共用容器/窗口。本弹窗只负责“开始录制 → 选择应用”，
// 白色圆角面板、无灰色描边/阴影、居中显示在主窗口上、不可拖动，
// 点击弹窗外空白处返回（退出选择模式，不关闭字幕浮层）。

private enum FloatingAppPickerMetrics {
    /// 弹窗（白色面板）尺寸。
    static let size = CGSize(width: 560, height: 360)
    static let cornerRadius: CGFloat = 10
}

// MARK: - SwiftUI 内容

struct FloatingAppPickerView: View {
    let viewModel: FloatingLetterViewModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    viewModel.dismissAppSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.black.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("返回")
            }
            .frame(height: 20)

            content
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        .background(
            // 纯白圆角面板。窗口阴影由系统绘制（hasShadow = true），
            // 与主界面使用同一套 AppKit 窗口阴影，观感完全一致。
            RoundedRectangle(cornerRadius: FloatingAppPickerMetrics.cornerRadius, style: .continuous)
                .fill(Color.white)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.appListPhase {
        case .loading, .idle:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在加载应用…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .permissionDenied:
            permissionDeniedContent
        case .ready:
            appListContent
        }
    }

    private var appListContent: some View {
        VStack(spacing: 8) {
            if let error = viewModel.appListError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索应用…", text: Binding(
                    get: { viewModel.appSearchText },
                    set: { viewModel.appSearchText = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                if !viewModel.appSearchText.isEmpty {
                    Button {
                        viewModel.appSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

            // 应用列表
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredApps) { app in
                        appRow(app)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)

            // 录制选项
            optionsRow

            // 操作按钮
            HStack(spacing: 10) {
                Button("取消") {
                    viewModel.cancelAppSelection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("开始录制") {
                    viewModel.confirmRecording()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .font(.system(size: 12, weight: .semibold))
                .disabled(viewModel.selectedAppID == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func appRow(_ app: FloatingLetterViewModel.FloatingApp) -> some View {
        Button {
            viewModel.selectApp(id: app.id)
        } label: {
            HStack(spacing: 8) {
                appIcon(processID: app.processID)
                    .frame(width: 18, height: 18)
                Text(app.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if viewModel.selectedAppID == app.id {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(viewModel.selectedAppID == app.id ? Color.blue.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var optionsRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Toggle(isOn: Binding(
                    get: { viewModel.includeMicrophone },
                    set: { _ in viewModel.toggleIncludeMicrophone() }
                )) {
                    Image(systemName: "mic")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Toggle(isOn: Binding(
                    get: { viewModel.enableLiveTranscription },
                    set: { _ in viewModel.toggleLiveTranscription() }
                )) {
                    Label("实时", systemImage: "text.word.spacing")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Toggle(isOn: Binding(
                    get: { viewModel.enableLiveTranslation },
                    set: { _ in viewModel.toggleLiveTranslation() }
                )) {
                    Image(systemName: "character.bubble")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!viewModel.enableLiveTranscription)

                Spacer()
            }

            if viewModel.enableLiveTranscription {
                HStack(spacing: 6) {
                    Text("实时模型：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("实时转录模型", selection: Binding(
                        get: { viewModel.liveModelSelection },
                        set: { viewModel.setLiveModelSelection($0) }
                    )) {
                        Text("与转录模型相同").tag("")
                        ForEach(viewModel.liveModelOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private var permissionDeniedContent: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("需要屏幕录制权限")
                .font(.headline)
            Text("WhisperASR 需要屏幕录制权限才能从其他应用捕获音频。")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                Button("打开系统设置") {
                    viewModel.openSystemSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("重试") {
                    viewModel.retryLoadApps()
                }
                .controlSize(.small)
            }
            Spacer()
            Button("取消") {
                viewModel.cancelAppSelection()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredApps: [FloatingLetterViewModel.FloatingApp] {
        let query = viewModel.appSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return viewModel.availableApps }
        return viewModel.availableApps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private func appIcon(processID: pid_t) -> some View {
        Group {
            if let runningApp = NSRunningApplication(processIdentifier: processID),
               let icon = runningApp.icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(contentMode: .fit)
    }
}

// MARK: - 面板与控制器

private final class FloatingAppPickerPanel: NSPanel {
    // 允许成为 key window：搜索框需要键盘输入。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingAppPickerController: NSObject {
    static let shared = FloatingAppPickerController()

    private let panel: FloatingAppPickerPanel
    private var hostingView: NSHostingView<FloatingAppPickerView>?
    private weak var viewModel: FloatingLetterViewModel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    private override init() {
        panel = FloatingAppPickerPanel(
            contentRect: NSRect(origin: .zero, size: FloatingAppPickerMetrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 主界面同款系统窗口阴影（AppKit 根据窗口内容形状绘制）。
        panel.hasShadow = true
        panel.level = .normal
        // 弹窗不可拖动（居中定位由控制器负责）。
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    var isVisible: Bool { panel.isVisible }

    func present(viewModel: FloatingLetterViewModel) {
        self.viewModel = viewModel

        let root = FloatingAppPickerView(viewModel: viewModel)
        if let hostingView {
            hostingView.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            hostingView = hosting
        }

        centerOnMainWindow()
        panel.orderFrontRegardless()
        startMonitoring()
    }

    func dismiss() {
        stopMonitoring()
        hostingView = nil
        panel.contentView = nil
        panel.orderOut(nil)
        viewModel = nil
    }

    /// 弹窗居中显示在主窗口上（找不到主窗口时居中屏幕）。
    private func centerOnMainWindow() {
        let size = FloatingAppPickerMetrics.size
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let mainFrame = NSApplication.shared.windows
            .first { $0.isVisible && $0.title == "WhisperASR" && $0 !== panel }?
            .frame
            ?? screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)

        var frame = NSRect(
            x: mainFrame.midX - size.width / 2,
            y: mainFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if let visible = screen?.visibleFrame {
            if frame.minX < visible.minX { frame.origin.x = visible.minX + 8 }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width - 8 }
            if frame.minY < visible.minY { frame.origin.y = visible.minY + 8 }
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height - 8 }
        }
        panel.setFrame(frame, display: true)
    }

    // MARK: 空白处返回

    private func startMonitoring() {
        stopMonitoring()
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor in
                self?.handleClick(at: NSEvent.mouseLocation)
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleClick(at: NSEvent.mouseLocation)
            }
        }
    }

    private func stopMonitoring() {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    /// 点击弹窗外空白处返回；点击字幕浮层区域不算空白（不打断浮层交互）。
    private func handleClick(at point: NSPoint) {
        guard panel.isVisible else { return }
        if FloatingLetterOverlayController.shared.overlayFrame?.contains(point) == true {
            return
        }
        if !panel.frame.contains(point) {
            viewModel?.dismissAppSelection()
        }
    }
}
