import Foundation

/// A deliberately explicit voice phrase; ordinary writing requests cannot
/// silently become durable memory.
enum ComposePersistentMemoryCommand: Equatable, Sendable {
    case remember(fact: String)
    case correct(oldFact: String, newFact: String)
    case inspectCurrentDocument
    case forgetCurrentDocument

    static func parse(_ speech: String) -> Self? {
        let text = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 8_300 else { return nil }
        if let prefix = text.range(
            of: #"^cadence[, ]+remember for later that\s+"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let fact = String(text[prefix.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fact.isEmpty, fact.utf8.count <= 4_096 else { return nil }
            return .remember(fact: fact)
        }
        if let prefix = text.range(
            of: #"^cadence[, ]+correct saved memory[:,]?\s+"#,
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
        let normalized = text.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.init(charactersIn: ".!?"))
        ).lowercased()
        switch normalized {
        case "cadence, what do you remember for this document",
             "cadence what do you remember for this document":
            return .inspectCurrentDocument
        case "cadence, forget saved facts for this document",
             "cadence forget saved facts for this document":
            return .forgetCurrentDocument
        default:
            return nil
        }
    }
}

/// Only the exact proposed fact is shown. The revision token stays inside the
/// coordinator until this same action receives an explicit Save decision.
struct ComposePersistentMemoryReviewProposal: Equatable, Sendable {
    let requestID: UUID
    let proposalID: UUID
    let fact: String
    var replacingFact: String? = nil
}

struct ComposePersistentMemoryForgetReview: Equatable, Sendable {
    let requestID: UUID
    let proposalID: UUID
    let factCount: Int
}
