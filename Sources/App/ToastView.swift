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
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 16)
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
        .animation(.easeInOut(duration: 0.25), value: message.wrappedValue)
    }
}
