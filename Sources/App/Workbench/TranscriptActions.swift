import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 转录内容的复制/导出/纪要动作（从 DetailView 拆出，视图与业务分离）。
@MainActor
enum TranscriptActions {

    static func copyContent(_ item: TranscriptionItem) {
        let text = item.segments.isEmpty
            ? item.fullText
            : item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copyTranslation(_ item: TranscriptionItem) {
        let text = item.translatedSegments
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func exportText(_ item: TranscriptionItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (item.fileName as NSString).deletingPathExtension + ".txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = item.segments.isEmpty
                ? item.fullText
                : item.segments.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func exportTranslation(_ item: TranscriptionItem) {
        let lang = item.translationLanguage ?? "translation"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (item.fileName as NSString).deletingPathExtension + "-\(lang).txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = item.translatedSegments
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func exportSubtitles(_ item: TranscriptionItem, format: SubtitleFormat) {
        let baseName = (item.fileName as NSString).deletingPathExtension
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = baseName + "." + format.fileExtension

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = SubtitleFormatter.make(format, segments: item.segments, title: baseName)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func generateMinutes(_ item: TranscriptionItem, prompt: MinutesPrompt,
                                store: MinutesPromptStore, openWindow: OpenWindowAction) {
        store.selectedPromptID = prompt.id
        MinutesGenerator.shared.generate(item: item, prompt: prompt)
        openWindow(id: "minutes")
    }

    static func hasGeneratedMinutes(for item: TranscriptionItem) -> Bool {
        let generator = MinutesGenerator.shared
        return generator.sourceItemID == item.id && generator.phase == .completed
    }
}
