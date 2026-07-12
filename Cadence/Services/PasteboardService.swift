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
enum TranscriptCopyCommit {
    @discardableResult
    static func perform(_ text: String, onSuccess: () -> Void) -> Bool {
        perform(text, using: SystemTextPasteboardWriter(), onSuccess: onSuccess)
    }

    @discardableResult
    static func perform(
        _ text: String,
        using pasteboard: TextPasteboardWriting,
        onSuccess: () -> Void
    ) -> Bool {
        guard pasteboard.replaceContents(with: text) else { return false }
        onSuccess()
        return true
    }
}

enum HUDCopyLastAction {
    @discardableResult
    static func perform(
        history: [TranscriptHistoryItem],
        copy: (TranscriptHistoryItem) -> Bool
    ) -> Bool {
        guard let latest = history.first else { return false }
        return copy(latest)
    }
}
