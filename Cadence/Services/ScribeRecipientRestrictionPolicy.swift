import Foundation
import OSLog

private let scribeRecipientRestrictionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeRecipientRestrictionPolicy"
)

/// Detects only clear, standalone recipient action restrictions. It deliberately
/// does not infer broader intent from unknown wording. Quoted search text and
/// explicit requests to remove a literal are excluded clause by clause.
enum ScribeRecipientRestrictionPolicy {
    static func extract(from speech: String) -> [ScribeRecipientRestriction] {
        var found: [ScribeRecipientRestriction] = []
        for clause in clauses(in: speech) {
            let unquoted = removingQuotedSpans(from: clause)
            guard !isExplicitLiteralRemoval(unquoted) else { continue }
            let normalized = normalize(unquoted)
            for restriction in ScribeRecipientRestriction.allCases where !found.contains(restriction) {
                if isSourceRestriction(restriction, clause: normalized) {
                    found.append(restriction)
                }
            }
        }
        return found
    }

    static func validate(
        output: String,
        requirements: [ScribeRecipientRestriction]
    ) throws {
        let outputClauses = clauses(in: output).map { normalize(removingQuotedSpans(from: $0)) }
        for requirement in requirements where !outputClauses.contains(where: { isOutputRestriction(requirement, clause: $0) }) {
            // Do not log text, request contents, or the generated output.
            scribeRecipientRestrictionLogger.debug("Recipient restriction omission detected")
            throw ScribeRecipientRestrictionValidationError.missing(requirement)
        }
    }

    // `noChanges` intentionally accepts only all-change equivalents. A code or
    // file-only promise is weaker and must not satisfy this broader restriction.
    private static func isSourceRestriction(_ restriction: ScribeRecipientRestriction, clause: String) -> Bool {
        switch restriction {
        case .noChanges:
            return matches(#"^(?:please\s+)?do\s+not\s+make\s+(?:any\s+)?changes$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"without\s+making\s+(?:any\s+)?changes"#
                )
        case .noCodeChanges:
            return matches(#"^(?:please\s+)?do\s+not\s+(?:change|modify|edit)\s+code$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"without\s+(?:changing|modifying|editing)\s+code"#
                )
        case .noFileEdits:
            return matches(#"^(?:please\s+)?do\s+not\s+(?:edit|modify|change)\s+files$"#, in: clause)
                || matches(#"^(?:please\s+)?leave\s+files\s+untouched$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"(?:without\s+(?:editing|modifying|changing)\s+files|leave\s+files\s+untouched)"#
                )
        case .noConfigurationChanges:
            return matches(#"^(?:please\s+)?do\s+not\s+(?:edit|modify|change)\s+(?:the\s+)?configuration$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"(?:without\s+(?:editing|modifying|changing)\s+(?:the\s+)?configuration|do\s+not\s+(?:edit|modify|change)\s+(?:the\s+)?configuration)"#
                )
        }
    }

    private static func isOutputRestriction(_ restriction: ScribeRecipientRestriction, clause: String) -> Bool {
        switch restriction {
        case .noChanges:
            return matches(#"^(?:please\s+)?(?:do\s+not|don['’]t)\s+make\s+(?:any\s+)?changes$"#, in: clause)
                || matches(#"^(?:please\s+)?make\s+no\s+changes$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"(?:make\s+no\s+changes|without\s+making\s+(?:any\s+)?changes)"#
                )
        case .noCodeChanges:
            return matches(#"^(?:please\s+)?(?:do\s+not|don['’]t)\s+(?:change|modify|edit)\s+code$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"(?:with\s+no\s+code\s+changes|without\s+(?:changing|modifying|editing)\s+code)"#
                )
        case .noFileEdits:
            return matches(#"^(?:please\s+)?(?:do\s+not|don['’]t)\s+(?:edit|modify|change)\s+files$"#, in: clause)
                || matches(#"^(?:please\s+)?leave\s+files\s+untouched$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"(?:with\s+no\s+file\s+edits|without\s+(?:editing|modifying|changing)\s+files|leave\s+files\s+untouched)"#
                )
        case .noConfigurationChanges:
            return matches(#"^(?:please\s+)?(?:do\s+not|don['’]t)\s+(?:edit|modify|change)\s+(?:the\s+)?configuration$"#, in: clause)
                || hasImperativeActionPrefix(clause) && hasCoordinatedRestrictionSuffix(
                    clause, primary: #"(?:with\s+no\s+configuration\s+changes|without\s+(?:editing|modifying|changing)\s+(?:the\s+)?configuration|do\s+not\s+(?:edit|modify|change)\s+(?:the\s+)?configuration)"#
                )
        }
    }

    private static func hasImperativeActionPrefix(_ clause: String) -> Bool {
        // A direct coding-agent address is still an imperative. Keep this
        // bounded to the same recipient vocabulary as the source recognizer;
        // reported speech and completed-action claims must not satisfy it.
        matches(#"^(?:(?:codex|(?:the\s+)?coding\s+agent),\s+)?(?:please\s+)?(?:(?:ask\s+(?:(?:the\s+)?(?:coding\s+)?(?:agent|assistant)|codex)\s+to\s+|draft\s+(?:a\s+)?(?:short\s+)?request\s+to\s+)?(?:inspect|investigate|explain|find|review|check|look\s+into))\b"#, in: clause)
    }

    /// Supports only conjunctions of other recognized restriction fragments;
    /// it does not attempt general natural-language coordination parsing.
    private static func hasCoordinatedRestrictionSuffix(_ clause: String, primary: String) -> Bool {
        let known = #"(?:without\s+making\s+(?:any\s+)?changes|without\s+(?:changing|modifying|editing)\s+code|without\s+(?:editing|modifying|changing)\s+files|make\s+no\s+changes|with\s+no\s+code\s+changes|with\s+no\s+file\s+edits|leave\s+files\s+untouched|without\s+(?:editing|modifying|changing)\s+(?:the\s+)?configuration|do\s+not\s+(?:edit|modify|change)\s+(?:the\s+)?configuration|with\s+no\s+configuration\s+changes)"#
        return matches("\\b(?:" + primary + ")(?:\\s+and\\s+" + known + ")*$", in: clause)
    }

    private static func clauses(in text: String) -> [String] {
        var result: [String] = []
        var clause = ""
        var quote: Character?
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if quote != nil {
                clause.append(character)
                if character == quote! { quote = nil }
                continue
            }
            if let closer = quoteCloser(
                for: character,
                previous: index > 0 ? characters[index - 1] : nil,
                next: index + 1 < characters.count ? characters[index + 1] : nil
            ) {
                quote = closer
                clause.append(character)
            } else if isClauseBoundary(character, next: index + 1 < characters.count ? characters[index + 1] : nil) {
                result.append(clause)
                clause = ""
            } else {
                clause.append(character)
            }
        }
        result.append(clause)
        return result
    }

    private static func removingQuotedSpans(from text: String) -> String {
        var result = ""
        var quote: Character?
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if quote != nil {
                if character == quote! { quote = nil }
                result.append(" ")
                continue
            }
            if let closer = quoteCloser(
                for: character,
                previous: index > 0 ? characters[index - 1] : nil,
                next: index + 1 < characters.count ? characters[index + 1] : nil
            ) {
                quote = closer
                result.append(" ")
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func quoteCloser(for character: Character, previous: Character?, next: Character?) -> Character? {
        switch character {
        case "\"": return "\""
        case "“": return "”"
        case "‘": return "’"
        case "«": return "»"
        case "`": return "`"
        case "'":
            // Apostrophes in contractions such as don't are not quote delimiters.
            guard !(previous?.isLetter == true && next?.isLetter == true) else { return nil }
            return "'"
        default: return nil
        }
    }

    private static func isExplicitLiteralRemoval(_ clause: String) -> Bool {
        matches(#"\b(?:remove|delete)\b\s+(?:(?:the|this)\s+)?(?:literal|phrase|string|text)\b"#, in: normalize(clause))
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isClauseBoundary(_ character: Character, next: Character?) -> Bool {
        if character == "!" || character == "?" || character.isNewline { return true }
        return character == "." && (next == nil || next?.isWhitespace == true)
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
