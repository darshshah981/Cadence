import Foundation

enum TranscriptHistoryPolicy {
    static let initialPreviewCount = 20
    static let expandedPreviewCount = 100

    static func inserting(
        _ item: TranscriptHistoryItem,
        into history: [TranscriptHistoryItem]
    ) -> [TranscriptHistoryItem] {
        [item] + history
    }

    static func upserting(
        _ item: TranscriptHistoryItem,
        into history: [TranscriptHistoryItem]
    ) -> [TranscriptHistoryItem] {
        [item] + history.filter { $0.id != item.id }
    }

    static func historyItem(
        for draft: ComposeHistoryDraft,
        existing history: [TranscriptHistoryItem],
        createdAt: Date = .now
    ) -> TranscriptHistoryItem? {
        let finalText = draft.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = draft.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty, !originalText.isEmpty else { return nil }

        return TranscriptHistoryItem(
            id: draft.requestID,
            text: finalText,
            createdAt: history.first(where: { $0.id == draft.requestID })?.createdAt ?? createdAt,
            analyticsSessionID: nil,
            composeOriginalText: draft.composedText == nil ? nil : originalText
        )
    }

    static func initialVisibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), initialPreviewCount)
    }

    static func expandedVisibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), expandedPreviewCount)
    }
}

enum TranscriptHistoryMarkdownFormatter {
    static func markdown(
        for history: [TranscriptHistoryItem],
        exportedAt: Date = .now
    ) -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]

        var sections = [
            "# Cadence Dictation History",
            "",
            "Exported \(timestampFormatter.string(from: exportedAt))",
            "",
            "\(history.count) dictations",
        ]

        for item in history {
            sections.append(contentsOf: ["", "## \(timestampFormatter.string(from: item.createdAt))", ""])
            if let originalText = item.composeOriginalText {
                sections.append(contentsOf: [
                    "**Compose result**",
                    "",
                    item.text,
                    "",
                    "**Original dictation**",
                    "",
                    originalText,
                ])
            } else {
                sections.append(item.text)
            }
        }

        return sections.joined(separator: "\n") + "\n"
    }
}
