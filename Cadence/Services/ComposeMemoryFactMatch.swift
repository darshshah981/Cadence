import Foundation

/// Exact, conservative match for a user-requested fact correction. It tolerates
/// case, whitespace, and terminal punctuation but never chooses between facts.
enum ComposeMemoryFactMatch {
    static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }
}
