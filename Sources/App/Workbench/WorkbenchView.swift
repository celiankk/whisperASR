import SwiftUI

/// 工作台根视图（方向 A：双栏 + 悬浮播放胶囊）。
///
/// 取代原 NavigationSplitView：左栏是固定宽度的历史 rail（自绘，
/// 换取行模板列宽的确定性），右栏是转录工作台。播放器不再是
/// 底部常驻条，而是浮在右栏底部的胶囊（见 PlayerCapsule）。
///
/// 约束：主窗口必须是全 App 唯一的「宽度 > 400 的普通窗口」，
/// MenuBarController 靠这个启发式找回主窗（MenuBarController.swift
/// showMainWindow）。这里不新增任何大窗口。
struct WorkbenchView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        HStack(spacing: 0) {
            HistoryRail()
                .frame(width: Metrics.railWidth)

            HairlineDivider(vertical: true)

            DetailView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.font, Type.text(Type.body))
    }
}
