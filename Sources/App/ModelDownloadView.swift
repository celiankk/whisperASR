import SwiftUI

/// 模型下载弹层（方案 8 接线：细进度轨 + 数字滚动 + 完成态描边收口）。
struct ModelDownloadView: View {
    @Binding var isPresented: Bool
    @State private var manager = ModelManager.shared
    @State private var selectedID = ModelCatalog.all[0].id

    private var model: WhisperModelInfo {
        ModelCatalog.model(id: selectedID) ?? ModelCatalog.all[0]
    }

    private var downloader: ModelDownloader {
        manager.downloader(for: model)
    }

    var body: some View {
        VStack(spacing: Metrics.xl) {
            switch downloader.state {
            case .prompt:
                promptView
            case .downloading:
                downloadingView
            case .completed:
                completedView
            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding(Metrics.xxl)
        .frame(width: 440)
    }

    private var promptView: some View {
        VStack(spacing: Metrics.xl) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(Corner.rect(Corner.large).fill(Ink.soft(Color.accentColor, 0.10)))

            Text("需要语音识别模型")
                .font(Type.text(Type.title, weight: .semibold))
                .titleTracking(Type.title)

            Text("声记需要语音识别模型才能转录音频。选择一个下载 — 你可以稍后在设置中添加更多或切换。")
                .multilineTextAlignment(.center)
                .font(Type.text(Type.caption))
                .foregroundStyle(Ink.secondary)

            Picker("模型", selection: $selectedID) {
                ForEach(ModelCatalog.all) { m in
                    Text("\(m.displayName) (\(m.approxSizeText))").tag(m.id)
                }
            }

            Text(model.detail)
                .font(Type.mono(Type.micro))
                .foregroundStyle(Ink.secondary.opacity(0.7))

            if downloader.hasResumeData {
                Text("此模型的上次下载被中断，可以继续下载。")
                    .font(Type.text(Type.caption))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Ink.secondary)
            }

            HStack(spacing: Metrics.lg) {
                Button("暂不") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(downloader.hasResumeData ? "继续下载" : "下载") {
                    downloader.startDownload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var downloadingView: some View {
        VStack(spacing: Metrics.xl) {
            Text("正在下载 \(model.displayName)…")
                .font(Type.text(Type.title, weight: .semibold))
                .titleTracking(Type.title)

            LinearProgressBar(progress: downloader.progress)

            Text(downloader.progressText)
                .font(Type.mono(Type.micro, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .contentTransition(.numericText())
                .animation(Motion.anim(Motion.standard(0.25)), value: downloader.progressText)

            if let eta = downloader.estimatedTimeRemaining {
                Text(eta)
                    .font(Type.mono(Type.micro))
                    .foregroundStyle(Ink.secondary.opacity(0.7))
                    .contentTransition(.numericText())
                    .animation(Motion.anim(Motion.standard(0.25)), value: eta)
            }

            Button("取消") {
                downloader.cancelDownload()
            }
        }
    }

    private var completedView: some View {
        VStack(spacing: Metrics.xl) {
            CheckDraw()

            Text("模型下载成功")
                .font(Type.text(Type.title, weight: .semibold))
                .titleTracking(Type.title)

            Text("\(model.displayName) 已保存并可以使用。")
                .font(Type.text(Type.caption))
                .foregroundStyle(Ink.secondary)

            Button("完成") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: Metrics.xl) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Palette.warn)
                .frame(width: 64, height: 64)
                .background(Corner.rect(Corner.large).fill(Ink.soft(Palette.warn, 0.12)))

            Text("下载失败")
                .font(Type.text(Type.title, weight: .semibold))
                .titleTracking(Type.title)

            Text(message)
                .font(Type.text(Type.caption))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: Metrics.lg) {
                Button("关闭") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("重试") {
                    downloader.startDownload()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// 完成态：圆环淡入 + 对勾描边收口（stroke trim 0→1，替代整图标瞬变）。
private struct CheckDraw: View {
    @State private var drawn = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.ok.opacity(0.22), lineWidth: 2)
            CheckShape()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(Palette.ok,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 44, height: 44)
        .onAppear {
            Motion.run(Motion.exit(0.42).delay(0.12)) { drawn = true }
        }
    }
}

private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: w * 0.22, y: h * 0.52))
        p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.72))
        p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.3))
        return p
    }
}
