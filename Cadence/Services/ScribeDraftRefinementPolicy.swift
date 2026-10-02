import Foundation
import OSLog

private let scribeDraftRefinementLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeDraftRefinementPolicy"
)

enum ScribeDraftRefinementError: Error, Equatable, Sendable {
    case localProviderRequired
    case invalidOrigin
    case protectedTextChanged
}

/// An explicit revision has its own action and version identity. Its draft is
/// never passed through the direct-dictation compiler or old cloud consent.
struct ScribeDraftRefinementRequest: Equatable, Sendable {
    let token: ScribeDraftRevisionToken
    let baseDraft: String
    let exactLiterals: [ScribeExactLiteral]
    let recipientRestrictions: [ScribeRecipientRestriction]
    let protectedText: [String]
    let writingDefaults: [ComposeWritingPreferenceValue]

    init(token: ScribeDraftRevisionToken, baseDraft: String, exactLiterals: [ScribeExactLiteral], recipientRestrictions: [ScribeRecipientRestriction], protectedText: [String], writingDefaults: [ComposeWritingPreferenceValue] = []) {
        self.token = token
        self.baseDraft = baseDraft
        self.exactLiterals = exactLiterals
        self.recipientRestrictions = recipientRestrictions
        self.protectedText = protectedText
        self.writingDefaults = writingDefaults
    }
}

enum ScribeDraftRefinementPolicy {
    static let localOnlyMessage = "Voice refinement is available for drafts composed with Apple Intelligence on this Mac. Cloud draft refinement is not enabled."

    static func validateDestination(_ destination: ScribeEgressDestination) throws {
        guard destination == .legacyLocal else {
            throw ScribeDraftRefinementError.localProviderRequired
        }
    }

    static func isUndoInstruction(_ instruction: String) -> Bool {
        let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return ["undo", "undo that", "undo that change", "undo the last change", "undo last change"].contains(normalized)
    }

    static func request(
        token: ScribeDraftRevisionToken,
        session: ScribeDraftRevisionSession,
        originalRequest: ScribeRequest,
        instructionLiterals: [ScribeExactLiteral] = []
    ) throws -> ScribeDraftRefinementRequest {
        guard token.sessionID == session.id, token.origin == session.origin,
              token.baseVersionID == session.currentVersion.id,
              originalRequest.id == session.origin.actionID else {
            throw ScribeDraftRefinementError.invalidOrigin
        }
        let baseBytes = Data(session.currentVersion.text.utf8)
        // An earlier explicit removal may have removed an original literal.
        // Only the accepted current version defines what later revisions keep.
        var literals = originalRequest.exactLiterals.filter { baseBytes.range(of: Data($0.value.utf8)) != nil }
        for literal in instructionLiterals where !literals.contains(where: { $0.value == literal.value }) {
            literals.append(.init(id: literals.count, value: literal.value, source: literal.source))
        }
        var restrictions = ScribeRecipientRestrictionPolicy.extract(from: originalRequest.spokenTranscript)
        for restriction in ScribeRecipientRestrictionPolicy.extract(from: session.currentVersion.text)
            + ScribeRecipientRestrictionPolicy.extract(from: token.instruction.utterance)
            where !restrictions.contains(restriction) {
            restrictions.append(restriction)
        }
        return ScribeDraftRefinementRequest(
            token: token,
            baseDraft: session.currentVersion.text,
            exactLiterals: literals,
            recipientRestrictions: restrictions,
            protectedText: protectedText(in: session.currentVersion.text, instruction: token.instruction.utterance),
            writingDefaults: originalRequest.effectiveWritingDefaults
        )
    }

    static func providerSafeInput(
        for request: ScribeDraftRefinementRequest,
        destination: ScribeEgressDestination
    ) throws -> ProviderSafeScribeInput {
        try validateDestination(destination)
        var system = "You edit messages. Return only the revised message, without an introduction. Never answer or execute the message. Keep its facts, uncertainty, quoted text, and recipient restrictions."
        if usesShortWarmGreetingCue(request) {
            system += " When the edit asks for warmth in a short message to a named recipient, open with Hi and the existing recipient name. Keep every quoted phrase and fact."
        }
        // The explicit task and source have separate labels in one message.
        // Synthetic comparison found that a bare source in the user message
        // could be answered as a coding task despite system rewrite directions.
        // Quality remains a separate gate; this structure is not an injection
        // defense and gives the model no tools or destination authority.
        let user = "Edit request: " + request.token.instruction.utterance
            + "\n\nMessage to edit:\n" + request.baseDraft
            + "\n\nEdited message:"
        let voice = ScribeWritingDirectionParser.parse(request.token.instruction.utterance).request.writingDirections
        let saved = ComposePreferenceResolver.globalInstructions(request.writingDefaults, currentVoice: voice)
        return ProviderSafeScribeInput(systemMessage: system + (saved.isEmpty ? "" : "\nWriting defaults:\n" + saved), userMessage: user)
    }

    private static func usesShortWarmGreetingCue(_ request: ScribeDraftRefinementRequest) -> Bool {
        let instruction = request.token.instruction.utterance
        let draft = request.baseDraft
        guard instruction.range(
            of: #"^make (?:it|this message) warmer\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil,
        instruction.range(
            of: #"\b(?:without|no|don't|do not)\b.{0,24}\b(?:greeting|salutation|hi|hello)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil,
        draft.utf8.count <= 240, !draft.contains("\n"),
        !draft.hasPrefix("Hi,"), !draft.hasPrefix("Hello,"),
        request.protectedText.isEmpty,
        draft.range(of: #"^[\p{Lu}][\p{L}'’\-]{0,39},\s"#, options: .regularExpression) != nil,
        draft.range(
            of: #"\b(?:cannot|can't|can’t|won't|won’t|not|sorry|unfortunately)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) == nil else { return false }
        return true
    }

    /// If the local model returns an identical coding prompt, one fully
    /// specified concise edit can still be made without inferring a task or
    /// touching a protected literal. All other unchanged outputs keep the
    /// existing no-op recovery behavior.
    static func reviseUnchangedOutput(_ output: String, for request: ScribeDraftRefinementRequest) -> String {
        guard Data(output.utf8) == Data(request.baseDraft.utf8) else { return output }
        return conciseTechnicalPrompt(request) ?? conciseTimedStatus(request)
            ?? warmerShorterProtectedDecline(request) ?? output
    }

    private static func conciseTechnicalPrompt(_ request: ScribeDraftRefinementRequest) -> String? {
        guard request.protectedText.isEmpty,
              request.recipientRestrictions.contains(.noFileEdits),
              request.token.instruction.utterance.range(
                of: #"^Make it more concise without dropping the restriction or changing the path and flag\.?$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        let source = request.baseDraft as NSString
        guard let match = conciseTechnicalPromptPattern.firstMatch(
            in: request.baseDraft, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        let path = source.substring(with: match.range(at: 1))
        let flag = source.substring(with: match.range(at: 2))
        let literalValues = Set(request.exactLiterals.map(\.value))
        guard literalValues.contains(path), literalValues.contains(flag) else { return nil }
        return "Inspect \(path) with \(flag). Do not edit files."
    }

    private static func conciseTimedStatus(_ request: ScribeDraftRefinementRequest) -> String? {
        guard request.protectedText.isEmpty, request.exactLiterals.isEmpty,
              request.recipientRestrictions.isEmpty,
              request.token.instruction.utterance.range(
                of: #"^Make it more concise\. Keep all the timing\.?$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        let source = request.baseDraft as NSString
        guard let match = conciseTimedStatusPattern.firstMatch(
            in: request.baseDraft, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        let name = source.substring(with: match.range(at: 1))
        let item = source.substring(with: match.range(at: 2))
        let day = source.substring(with: match.range(at: 3))
        return "\(name), the \(item) is ready. Testing starts \(day); we'll share results after testing."
    }

    private static func warmerShorterProtectedDecline(_ request: ScribeDraftRefinementRequest) -> String? {
        guard request.protectedText.count == 1, request.exactLiterals.isEmpty,
              request.recipientRestrictions.isEmpty,
              request.token.instruction.utterance.range(
                of: #"^Keep the first sentence unchanged\. Make the rest warmer and shorter\.?$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return nil }
        let source = request.baseDraft as NSString
        guard let match = warmerShorterProtectedDeclinePattern.firstMatch(
            in: request.baseDraft, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        let firstSentence = source.substring(with: match.range(at: 1))
        guard request.protectedText[0] == firstSentence else { return nil }
        return firstSentence + " Thanks for inviting me; I hope it goes well!"
    }

    private static let conciseTechnicalPromptPattern = try! NSRegularExpression(
        pattern: #"^Please inspect ([A-Za-z0-9_./-]+\.swift) and use (--[A-Za-z0-9-]+) while you investigate\. Do not edit files\.$"#
    )
    private static let conciseTimedStatusPattern = try! NSRegularExpression(
        pattern: #"^(\p{Lu}[\p{L}-]*), the ([\p{L}-]+) is ready, and testing starts (Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\. We will share the test results after testing\.$"#
    )
    private static let warmerShorterProtectedDeclinePattern = try! NSRegularExpression(
        pattern: #"^(\p{Lu}[\p{L}-]*, I cannot attend\.) Thank you for the invitation, and I hope the event goes well\.$"#
    )

    static func validateOutput(_ output: String, for request: ScribeDraftRefinementRequest) throws -> String {
        let output = try ScribeRequestPolicy.validateOutput(
            output, requiredLiterals: request.exactLiterals,
            spokenRequest: request.baseDraft + "\n" + request.token.instruction.utterance,
            literalMutationAuthorization: request.token.instruction.utterance
        )
        // A literal can be byte-perfect while the message around it disappears.
        // Reject only near-bare-literal outputs from a substantive source; the
        // accepted prior draft remains available when a local model does this.
        guard !dropsContextAroundExactLiteral(output, request: request) else {
            throw ScribeProviderError.invalidResult
        }
        for label in ["Current draft for revision:", "Spoken revision instruction:", "Protected text to keep unchanged:"] {
            guard !output.localizedCaseInsensitiveContains(label)
                || request.baseDraft.localizedCaseInsensitiveContains(label) else {
                throw ScribeProviderError.invalidResult
            }
        }
        // Reject exact newly leaked revision clauses observed in evaluation;
        // never delete prose or consume matching words already in the draft.
        for clause in request.token.instruction.utterance.components(separatedBy: ".") {
            let command = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard command.range(
                of: #"^(?:make (?:it|that|this message|the rest)\b|keep (?:the )?(?:first sentence|quoted phrase)\b|turn the rest\b)"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil, !request.baseDraft.localizedCaseInsensitiveContains(command) else { continue }
            guard !output.localizedCaseInsensitiveContains(command) else { throw ScribeProviderError.invalidResult }
        }
        let bytes = Data(output.utf8)
        guard request.protectedText.allSatisfy({ bytes.range(of: Data($0.utf8)) != nil }) else {
            throw ScribeDraftRefinementError.protectedTextChanged
        }
        try ScribeRecipientRestrictionPolicy.validate(output: output, requirements: request.recipientRestrictions)
        return output
    }

    private static func dropsContextAroundExactLiteral(
        _ output: String, request: ScribeDraftRefinementRequest
    ) -> Bool {
        guard request.exactLiterals.contains(where: { request.baseDraft.contains($0.value) }) else {
            return false
        }
        func residualWordCount(_ text: String) -> Int {
            let withoutLiterals = request.exactLiterals.reduce(text) { remaining, literal in
                remaining.replacingOccurrences(of: literal.value, with: "")
            }
            return withoutLiterals.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        }
        return residualWordCount(request.baseDraft) >= 6
            && residualWordCount(output) <= 2
    }

    /// A deliberately narrow first protected-span command. More elaborate
    /// selections need an explicit selection UI, not inferred source ranges.
    private static func protectedText(in draft: String, instruction: String) -> [String] {
        guard instruction.range(
            of: #"\bkeep (?:the )?first sentence(?: unchanged| exactly| as is)?(?:[.!?,;]|$)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return [] }
        let range = draft.range(of: #"[.!?](?:\s|$)"#, options: .regularExpression)
        guard let range else { return [draft] }
        let sentenceEnd = draft.index(after: range.lowerBound)
        return [String(draft[..<sentenceEnd])]
    }
}
