import AppKit
import SwiftUI

// MARK: - 拖拽式权限授权引导（PermissionDragGuide）
//
// 对标系统级工具的拖入即授权引导：左边可拖拽的 app 图标卡片 + 右边
// 操作说明。用户按住图标卡片拖进「系统设置 → 隐私与安全性」对应
// 权限列表（屏幕录制/辅助功能/麦克风），松手即完成添加授权——
// 免去「打开设置 → 点 + → 文件选择器逐级找 app」的流程。
//
// 拖拽数据：app 自身 file URL（系统设置权限列表接受 .app 拖入）。
// 授权状态由调用方轮询/手动刷新（系统不提供变更通知）。

/// 拖拽式权限授权引导卡（常驻显示：状态徽标随授权状态变化）。
struct PermissionDragGuide: View {
    /// 权限名称（标题与拖拽说明中引用，如「屏幕录制」）。
    let permissionName: String
    /// 系统设置深链（打开对应权限面板作为拖拽的替代路径）。
    let settingsURL: URL
    /// 当前是否已授权（true = 卡片顶部显示已授权徽标）。
    var isGranted: Bool = false
    /// 授权状态变化回调（「请求授权…」按钮 + 「重新检测」共用：
    /// 调用方注入 CGRequestScreenCaptureAccess + refresh）。
    var onRecheck: (() -> Void)? = nil

    @State private var appURL: URL? = Bundle.main.bundleURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 标题行：权限名 + 授权状态徽标。
            HStack(spacing: 6) {
                Text(permissionName)
                    .font(.system(size: 12, weight: .semibold))
                if isGranted {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("未授权", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            HStack(spacing: 16) {
                // 可拖拽的 app 图标卡片。
                HStack(spacing: 10) {
                    // AppKit beginDraggingSession：SwiftUI .onDrag 跨 app
                    // 拖系统设置不可靠，且 .gesture(DragGesture) 与 .onDrag
                    // 冲突导致拖拽根本无法启动。
                    DraggableAppIcon(fileURL: Bundle.main.bundleURL, iconSide: 40)
                        .frame(width: 36, height: 36)
                    Text("WhisperASR")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
                .help("按住图标拖到系统设置列表中")

                Spacer()

                // 操作说明。
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.up.forward.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        (Text("把左边的图标拖进上方的")
                            + Text(" \(permissionName) ")
                                .fontWeight(.semibold)
                            + Text("列表"))
                            .font(.system(size: 12))
                        Text("松手即完成授权，无需再点开关")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 主路径：请求授权（系统弹窗）；替代路径：打开系统设置。
                VStack(spacing: 6) {
                    if !isGranted {
                        Button("请求授权…") {
                            onRecheck?()   // 调用方注入 requestAccess
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(settingsURL)
                        // 悬浮授权窗：附着在系统设置下方（置顶不抢焦点），
                        // 直接把图标拖进权限列表。
                        PermissionGuidePanelController.shared.show(
                            permissionName: permissionName, settingsURL: settingsURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if let onRecheck {
                        Button("重新检测") { onRecheck() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

}
