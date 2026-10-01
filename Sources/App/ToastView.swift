import SwiftUI

/// A transient, auto-dismissing toast shown at the bottom of the main window.
/// Used for translation errors (expired/invalid API key, failed API calls) that
/// shouldn't interrupt the user with a modal dialog.
struct ToastView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.warn)
            Text(message)
                .font(Type.text(Type.body))
                .foregroundStyle(Color.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: Corner.rect(Corner.card))
        .overlay(Corner.rect(Corner.card).strokeBorder(Ink.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 2.5, y: 2)
        .shadow(color: .black.opacity(0.10), radius: 14, y: 10)
        .padding(.bottom, Metrics.xxl)
    }
}

extension View {
    /// Overlays an auto-dismissing toast bound to an optional message.
    func toast(message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                ToastView(message: text) {
                    message.wrappedValue = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.anim(Motion.exit(0.3)), value: message.wrappedValue)
    }
}
