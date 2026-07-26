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
            sections.append(contentsOf: [
                "",
                "## \(timestampFormatter.string(from: item.createdAt))",
                "",
                item.text,
            ])
        }

        return sections.joined(separator: "\n") + "\n"
    }
}
