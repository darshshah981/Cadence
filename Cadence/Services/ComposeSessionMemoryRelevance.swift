import Foundation
import OSLog

private let composeSessionMemoryRelevanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeSessionMemoryRelevance"
)

/// Conservative lexical matching for local-memory drafting. A short, explicit
/// follow-up request may use the only user-stated fact in the verified scope;
/// ambiguous or unrelated requests never fall back to all saved facts.
enum ComposeSessionMemoryRelevance {
    private static let commonWords: Set<String> = [
        "about", "also", "another", "could", "document", "draft", "email",
        "from", "have", "into", "message", "more", "please", "project",
        "reply", "request", "send", "should", "their", "there", "these",
        "they", "this", "those", "update", "what", "when", "where",
        "which", "with", "would", "write", "your"
    ]

    private static let singleFactFollowUps: Set<String> = [
        "ask for an update", "please ask for an update", "could you ask for an update",
        "ask them for an update", "please ask them for an update",
        "follow up on this", "please follow up on this",
        "ask for an update on this", "please ask for an update on this"
    ]

    static func select(
        _ records: [ScribeSessionMemoryRecord], for spokenRequest: String
    ) -> [ScribeSessionMemoryRecord] {
        if singleFactFollowUps.contains(normalizedWords(in: spokenRequest)) {
            guard records.count == 1, records[0].kind == .explicitUserFact else { return [] }
            composeSessionMemoryRelevanceLogger.debug("Single-fact local follow-up selected")
            return records
        }
        let requestWords = words(in: spokenRequest)
        guard !requestWords.isEmpty else { return [] }
        let result = records.filter { !words(in: $0.text).isDisjoint(with: requestWords) }
        composeSessionMemoryRelevanceLogger.debug("Local draft fact selection completed")
        return result
    }

    static func needsClarification(
        _ records: [ScribeSessionMemoryRecord], for spokenRequest: String
    ) -> Bool {
        singleFactFollowUps.contains(normalizedWords(in: spokenRequest)) && records.count > 1
    }

    private static func words(in text: String) -> Set<String> {
        Set(normalizedWords(in: text).split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 4 && !commonWords.contains($0) })
    }

    private static func normalizedWords(in text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
