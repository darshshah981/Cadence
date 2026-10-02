import Foundation

/// Only exact, invocation-level voice commands may request memory operations.
/// This parser does not infer facts from ordinary drafts or visible app text.
enum ComposeSessionMemoryCommand: Equatable, Sendable {
    case remember(fact: String)
    case correct(oldFact: String, newFact: String)
    case inspectCurrentDocument
    case forgetCurrentDocument

    static func parse(_ speech: String) -> Self? {
        let text = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4_200 else { return nil }
        if let prefix = text.range(
            of: #"^cadence[, ]+correct memory[:,]?\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let body = String(text[prefix.upperBound...])
            guard let delimiter = body.range(of: " should be ", options: .caseInsensitive) else {
                return nil
            }
            let old = String(body[..<delimiter.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let new = String(body[delimiter.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !old.isEmpty, !new.isEmpty,
                  old.utf8.count <= 4_096, new.utf8.count <= 4_096 else { return nil }
            return .correct(oldFact: old, newFact: new)
        }
        if let prefix = text.range(of: #"^remember that\s+"#, options: [.regularExpression, .caseInsensitive]) {
            let fact = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty, fact.utf8.count <= 4_096 else { return nil }
            return .remember(fact: fact)
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".!?")))
            .lowercased()
        switch normalized {
        case "what do you remember for this document", "show what you remember for this document":
            return .inspectCurrentDocument
        case "forget this document", "forget what you remember for this document":
            return .forgetCurrentDocument
        default:
            return nil
        }
    }
}

/// Local UI feedback for an explicit voice-memory command. The detail may
/// contain user facts and must never be logged or sent to a provider.
struct ComposeSessionMemoryNotice: Equatable, Sendable {
    let requestID: UUID
    let title: String
    let detail: String
}
