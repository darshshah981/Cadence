import AppKit

@MainActor
protocol TextPasteboardWriting {
    @discardableResult
    func replaceContents(with text: String) -> Bool
}

@MainActor
struct SystemTextPasteboardWriter: TextPasteboardWriting {
    @discardableResult
    func replaceContents(with text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

@MainActor
enum TranscriptPasteboardAction {
    @discardableResult
    static func copy(_ text: String) -> Bool {
        copy(text, using: SystemTextPasteboardWriter())
    }

    @discardableResult
    static func copy(_ text: String, using pasteboard: TextPasteboardWriting) -> Bool {
        pasteboard.replaceContents(with: text)
    }
}

enum HUDCopyLastAction {
    @discardableResult
    static func perform(
        history: [TranscriptHistoryItem],
        copy: (TranscriptHistoryItem) -> Void
    ) -> Bool {
        guard let latest = history.first else { return false }
        copy(latest)
        return true
    }
}
