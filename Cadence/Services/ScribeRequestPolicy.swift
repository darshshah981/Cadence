import Foundation

enum ScribeRequestPolicy {
    static let systemMessage = """
    You are Cadence Scribe, a writing assistant. Produce one draft for direct review and insertion.
    Return only the draft: no preface, explanation, label, surrounding quotation marks, or fence around the entire response.
    Follow the Writing behavior. Use the Processed dictation as the source of the user's intended meaning.
    Do not invent project facts, names, dates, commitments, links, files, code, commands, specific constraints, outcomes, or relationships.
    Preserve provided names, mentions, numbers, URLs, code literals, paths, identifiers, commands, and quoted text exactly.
    If the request is ambiguous, preserve the ambiguity concisely instead of making a consequential assumption.
    """

    static func providerSafeInput(
        for request: ScribeRequest,
        destination: ScribeEgressDestination
    ) throws -> ProviderSafeScribeInput {
        try validateEgress(request, destination: destination)
        let spokenRequestJSON = try jsonString(["processed_dictation": request.spokenTranscript])
        var sections = [
            "Processed dictation (JSON data):\n\(spokenRequestJSON)"
        ]
        sections.append("Writing behavior:\n\(behaviorInstructions(for: request))")

        if !request.exactLiterals.isEmpty {
            let literals = request.exactLiterals.map { literal in
                ["id": literal.id, "value": literal.value] as [String: Any]
            }
            sections.append(
                "Exact literals (JSON data) — preserve each value byte-for-byte:\n"
                    + (try jsonString(literals))
            )
        }
        return ProviderSafeScribeInput(
            systemMessage: systemMessage,
            userMessage: sections.joined(separator: "\n\n")
        )
    }

    static func validateEgress(
        _ request: ScribeRequest,
        destination: ScribeEgressDestination
    ) throws {
        guard destination.disclosureVersion == ScribeProviderDisclosure.currentVersion,
              !destination.recipientOrigin.isEmpty else {
            throw ScribeProviderError.invalidResult
        }

        // The only egress data is compiled guidance, processed dictation, and
        // literal metadata. Context/target/provider identity never crosses this boundary.
        guard request.context == nil else { throw ScribeProviderError.invalidResult }
    }

    static func validateOutput(
        _ output: String,
        requiredLiterals: [ScribeExactLiteral],
        spokenRequest: String
    ) throws -> String {
        let normalized = try ScribeOutputPolicy.normalizedOutput(output)
        guard requiredLiterals.allSatisfy({ literal in
            normalized.contains(literal.value)
                || explicitlyAuthorizesMutation(of: literal.value, in: spokenRequest)
        }) else {
            throw ScribeProviderError.invalidResult
        }
        return normalized
    }

    private static func explicitlyAuthorizesMutation(
        of literal: String,
        in spokenRequest: String
    ) -> Bool {
        guard !literal.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: literal)
        let pattern = "\\b(?:rename|remove)\\b\\s+(?:(?:the|this)\\s+)?(?:(?:literal|identifier|flag|path|command)\\s+)?[`\"'“”‘’]?\(escaped)[`\"'“”‘’]?"
        return spokenRequest.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func jsonString(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ScribeProviderError.invalidResult
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw ScribeProviderError.invalidResult
        }
        return encoded
    }

    private static func behaviorInstructions(for request: ScribeRequest) -> String {
        if let guidance = request.resolvedGuidance {
            var sections = [guidance.compiledPresetInstructions]
            if let custom = guidance.customGuidance?.rawValue {
                sections.append("Additional guidance:\n\(custom)")
            }
            return sections.joined(separator: "\n\n")
        }
        if let environment = request.resolvedEnvironment {
            return environment.compiledInstructions
        }
        if let style = request.style {
            return """
            Tone: \(style.tone.displayName)
            Length: \(style.length.displayName)
            Punctuation: \(style.punctuation.displayName)
            Formatting: \(style.formatting.displayName)
            Preserve code literally: \(style.preservesCodeLiterals ? "yes" : "no")
            """
        }
        return "Write a clear, concise draft that follows the spoken request without adding unsupported detail."
    }
}
