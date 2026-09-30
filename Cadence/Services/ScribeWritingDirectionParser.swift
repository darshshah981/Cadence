import Foundation
import OSLog

private let scribeWritingDirectionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeWritingDirections"
)

/// Recognizes a deliberately small set of standalone writing commands at
/// request edges. It records protected source text instead of deleting phrases
/// that merely resemble a command.
enum ScribeWritingDirectionParser {
    struct Result: Equatable {
        let request: ScribeWritingRequest
        /// Exact edge commands removed from the intended message. These are
        /// evidence for output validation, not text to remove from a result.
        var consumedCommands: [String] = []

        /// Compatibility aliases for the existing focused rewrite path.
        var content: String { request.message }
        var instructions: [String] {
            request.unresolvedReferences.isEmpty ? request.writingDirections.map(\.instruction) : []
        }
        var unresolvedReferences: [ScribeUnresolvedReference] { request.unresolvedReferences }
    }

    static func parse(_ speech: String, protectedValues: [String] = []) -> Result {
        var protectedSpans = spans(for: protectedValues, in: speech, kind: .exactLiteral)

        // "Include this URL/phrase in the update" has no update to modify
        // when it is the whole utterance. Keep the exact literal intact and
        // require a source instead of presenting the bare URL or phrase as a
        // finished draft. A contentful preceding sentence remains untouched.
        if sourceFreeModifierPatterns.contains(where: {
            speech.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }) {
            return unchanged(
                speech: speech, protectedSpans: protectedSpans,
                unresolved: [.sourceRequired(transform: .rewrite)]
            )
        }

        // Quotation/literal requests intentionally bypass command extraction.
        // The full source remains protected, including spoken quotes without
        // punctuation, so a future grammar cannot consume it by accident.
        guard speech.range(of: quotationOrLiteralPattern,
                           options: [.regularExpression, .caseInsensitive]) == nil else {
            protectedSpans.append(.init(
                utf16Range: 0..<(speech as NSString).length,
                value: speech,
                kind: .quotedOrLiteralRequest
            ))
            return Result(request: ScribeWritingRequest(
                originalTranscript: speech,
                message: speech,
                protectedSpans: protectedSpans
            ))
        }

        // A standalone summarization command has no source in ordinary
        // Compose. Do not ask the model to invent a document or insert the
        // command itself as if it were a drafted message. Selected-text
        // summarization needs its own certified operation and is not implied.
        if speech.range(of: standaloneSummaryPattern,
                        options: [.regularExpression, .caseInsensitive]) != nil {
            return unchanged(
                speech: speech, protectedSpans: protectedSpans,
                unresolved: [.sourceRequired(transform: .rewrite)]
            )
        }

        // A deictic reply needs a certified source message and destination in
        // the same conversation. The active insertion field alone supplies
        // neither; do not let a model invent what "this" referred to.
        if speech.range(of: standaloneContextReplyPattern,
                        options: [.regularExpression, .caseInsensitive]) != nil,
           !isProtected(speech, values: protectedValues) {
            return unchanged(
                speech: speech, protectedSpans: protectedSpans,
                directions: [.reply],
                unresolved: [.sourceRequired(transform: .reply)]
            )
        }

        // An uncounted bullet transformation is also source-free. A leading
        // bullet command followed by a colon and actual content remains a
        // separate, contentful composition request.
        if speech.range(of: standaloneUncountedBulletsPattern,
                        options: [.regularExpression, .caseInsensitive]) != nil {
            return unchanged(
                speech: speech, protectedSpans: protectedSpans,
                unresolved: [.sourceRequired(transform: .rewrite)]
            )
        }

        if let match = match(wholeCommandPattern, in: speech),
           !isProtected(match.command, values: protectedValues) {
            let parsedDirections = directions(for: match.command)
            return unchanged(
                speech: speech,
                protectedSpans: protectedSpans,
                directions: parsedDirections,
                unresolved: [.sourceRequired(transform: transform(for: parsedDirections))]
            )
        }

        var content = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        var recognizedDirections: [ScribeWritingDirection] = []
        var consumedCommands: [String] = []

        while let match = match(leadingPattern, in: content),
              !isProtected(match.command, values: protectedValues) {
            append(directions(for: match.command), to: &recognizedDirections)
            consumedCommands.append(match.command)
            content = (content as NSString).substring(from: NSMaxRange(match.range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A counted-bullet request is recognized only as a leading colon
        // command, which separates it from actual message content.
        if let match = match(leadingBulletsPattern, in: content),
           !isProtected(match.command, values: protectedValues) {
            append(directions(for: match.command), to: &recognizedDirections)
            consumedCommands.append(match.command)
            content = (content as NSString).substring(from: NSMaxRange(match.range))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var trailingCommands: [String] = []
        while let match = match(trailingPattern, in: content),
              !isProtected(match.command, values: protectedValues) {
            trailingCommands.append(match.command)
            content = (content as NSString).substring(to: match.commandRange.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Transcription can omit the question boundary in a short greeting.
        // Recognize only a complete greeting followed by this explicit tone
        // command; a general whitespace boundary could consume recipient tasks.
        if let match = match(unpunctuatedFormalGreetingPattern, in: content),
           !isProtected(match.command, values: protectedValues) {
            trailingCommands.append(match.command)
            content = (content as NSString).substring(to: match.commandRange.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for command in trailingCommands.reversed() {
            append(directions(for: command), to: &recognizedDirections)
            consumedCommands.append(command)
        }

        if let match = match(wholeCommandPattern, in: content),
           !isProtected(match.command, values: protectedValues) {
            append(directions(for: match.command), to: &recognizedDirections)
            return unchanged(
                speech: speech,
                protectedSpans: protectedSpans,
                directions: recognizedDirections,
                unresolved: [.sourceRequired(transform: transform(for: recognizedDirections))]
            )
        }

        guard !content.isEmpty else {
            // A standalone transform has no source in the current direct-
            // dictation contract. Do not ask a provider to invent one.
            return unchanged(
                speech: speech,
                protectedSpans: protectedSpans,
                directions: recognizedDirections,
                unresolved: [.sourceRequired(transform: transform(for: recognizedDirections))]
            )
        }

        // This is intentionally a conversational setup, not a broad phrase
        // deletion rule. It can disappear only after a real writing command
        // has been recognized and only when a non-recipient message remains.
        if !recognizedDirections.isEmpty,
           let withoutSetup = removingLeadingConversationalSetup(from: content),
           !withoutSetup.isEmpty,
           recipientFrame(in: withoutSetup) == nil {
            content = withoutSetup
        }

        let frame = recipientFrame(in: content)
        if isRecipientInstruction(content) {
            protectedSpans.append(.init(
                utf16Range: sourceRange(of: content, in: speech),
                value: content,
                kind: .recipientInstruction
            ))
        }
        return Result(request: ScribeWritingRequest(
            originalTranscript: speech,
            message: content,
            writingDirections: recognizedDirections,
            protectedSpans: protectedSpans,
            recipientFrame: frame
        ), consumedCommands: consumedCommands)
    }

    private struct Match {
        let range: NSRange
        let commandRange: NSRange
        let command: String
    }

    private static func match(_ expression: NSRegularExpression, in text: String) -> Match? {
        let source = text as NSString
        guard let result = expression.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        let commandRange = result.range(at: 1)
        return Match(range: result.range, commandRange: commandRange, command: source.substring(with: commandRange))
    }

    private static func append(_ additions: [ScribeWritingDirection], to directions: inout [ScribeWritingDirection]) {
        for direction in additions {
            switch direction {
            case .tone:
                directions.removeAll { if case .tone = $0 { return true }; return false }
            case .concise:
                directions.removeAll { $0 == .concise }
            case .reply:
                directions.removeAll { $0 == .reply }
            case .bullets:
                directions.removeAll { if case .bullets = $0 { return true }; return false }
            case .avoidGivingReason:
                directions.removeAll { $0 == .avoidGivingReason }
            }
            directions.append(direction)
        }
    }

    private static func directions(for command: String) -> [ScribeWritingDirection] {
        let value = command.lowercased()
        var directions: [ScribeWritingDirection] = []
        directions.append(contentsOf: tones(in: value))
        if value.contains("concise") || value.contains("short") || value.contains("brief") { directions.append(.concise) }
        if value.contains("do not give a reason") { directions.append(.avoidGivingReason) }
        if match(replyPattern, in: command) != nil { directions.append(.reply) }
        if let bullets = bulletCount(in: value) { directions.append(.bullets(count: bullets)) }
        return directions
    }

    private static func transform(for directions: [ScribeWritingDirection]) -> ScribeSourceTransform {
        directions.contains(.reply) ? .reply : .rewrite
    }

    private static func tones(in command: String) -> [ScribeWritingDirection] {
        let expression = try! NSRegularExpression(
            pattern: #"\b(formal|formally|casual|casually|polite|politely|professional|professionally|polished|warm|warmer|friendly|friendlier|upbeat)\b"#,
            options: .caseInsensitive
        )
        let source = command as NSString
        return expression.matches(in: command, range: NSRange(location: 0, length: source.length)).compactMap {
            switch source.substring(with: $0.range(at: 1)).lowercased() {
            case "formal", "formally": return .tone(.formal)
            case "casual", "casually": return .tone(.casual)
            case "polite", "politely": return .tone(.polite)
            case "professional", "professionally", "polished": return .tone(.professional)
            case "warm", "warmer", "friendly", "friendlier": return .tone(.warm)
            case "upbeat": return .tone(.upbeat)
            default: return nil
            }
        }
    }

    private static func unchanged(
        speech: String,
        protectedSpans: [ScribeProtectedSpan],
        directions: [ScribeWritingDirection] = [],
        unresolved: [ScribeUnresolvedReference] = []
    ) -> Result {
        Result(request: ScribeWritingRequest(
            originalTranscript: speech,
            message: speech,
            writingDirections: directions,
            protectedSpans: protectedSpans,
            unresolvedReferences: unresolved
        ))
    }

    private static func bulletCount(in command: String) -> Int? {
        let pattern = #"\b(one|two|three|1|2|3)\s+bullets?\b"#
        guard let range = command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        switch command[range].lowercased() {
        case "one bullet", "one bullets", "1 bullet", "1 bullets": return 1
        case "two bullets", "two bullet", "2 bullets", "2 bullet": return 2
        case "three bullets", "three bullet", "3 bullets", "3 bullet": return 3
        default: return nil
        }
    }

    private static func spans(
        for values: [String],
        in text: String,
        kind: ScribeProtectedSpan.Kind
    ) -> [ScribeProtectedSpan] {
        let source = text as NSString
        return values.flatMap { value -> [ScribeProtectedSpan] in
            guard !value.isEmpty else { return [] }
            var spans: [ScribeProtectedSpan] = []
            var search = NSRange(location: 0, length: source.length)
            while true {
                let found = source.range(of: value, options: [.caseInsensitive], range: search)
                guard found.location != NSNotFound, found.length > 0 else { break }
                spans.append(.init(
                    utf16Range: found.location..<(found.location + found.length),
                    value: source.substring(with: found),
                    kind: kind
                ))
                let next = found.location + found.length
                guard next < source.length else { break }
                search = NSRange(location: next, length: source.length - next)
            }
            return spans
        }
    }

    private static func sourceRange(of content: String, in source: String) -> Range<Int> {
        let location = (source as NSString).range(of: content).location
        let safeLocation = location == NSNotFound ? 0 : location
        return safeLocation..<(safeLocation + (content as NSString).length)
    }

    private static func isProtected(_ command: String, values: [String]) -> Bool {
        values.contains { $0.range(of: command, options: .caseInsensitive) != nil }
    }

    private static func isRecipientInstruction(_ text: String) -> Bool {
        text.range(
            of: #"^\s*(?:tell|ask)\s+(?:the\s+)?[\p{L}\p{N}_-]+(?:\s+[\p{L}\p{N}_-]+){0,3}\s+to\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func recipientFrame(in text: String) -> ScribeRecipientFrame? {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)

        if let match = tellRecipientPattern.firstMatch(in: text, range: range) {
            let name = source.substring(with: match.range(at: 1))
            let bodyRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            return .init(kind: .tell, recipient: .named(name), body: source.substring(with: bodyRange))
        }
        if let match = tellNamedNegativeToPattern.firstMatch(in: text, range: range) {
            return .init(
                kind: .tell,
                recipient: .named(source.substring(with: match.range(at: 1))),
                body: "do not " + source.substring(with: match.range(at: 2))
            )
        }
        if let match = tellStatusOrNegativeRecipientPattern.firstMatch(in: text, range: range) {
            return .init(
                kind: .tell,
                recipient: .named(source.substring(with: match.range(at: 1))),
                body: source.substring(with: match.range(at: 2))
            )
        }
        if let match = draftMessageRecipientPattern.firstMatch(in: text, range: range) {
            return .init(
                kind: .tell,
                recipient: .named(source.substring(with: match.range(at: 1))),
                body: source.substring(with: match.range(at: 2))
            )
        }
        if let match = namedReplyRecipientPattern.firstMatch(in: text, range: range)
            ?? namedResponseRecipientPattern.firstMatch(in: text, range: range) {
            return .init(
                kind: .tell,
                recipient: .named(source.substring(with: match.range(at: 1))),
                body: source.substring(with: match.range(at: 2))
            )
        }
        if let match = askNamedRecipientPattern.firstMatch(in: text, range: range) {
            return .init(
                kind: .ask,
                recipient: .named(source.substring(with: match.range(at: 1))),
                body: source.substring(with: match.range(at: 2))
            )
        }
        if let match = askCodingAgentPattern.firstMatch(in: text, range: range) {
            let prefix = source.substring(with: match.range(at: 1)).lowercased() == "why" ? "why " : ""
            return .init(
                kind: .ask,
                recipient: .codingAgent,
                body: prefix + source.substring(with: match.range(at: 2))
            )
        }
        return nil
    }

    private static func removingLeadingConversationalSetup(from text: String) -> String? {
        guard let match = leadingConversationalSetupPattern.firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        ) else {
            return nil
        }
        return (text as NSString).substring(from: NSMaxRange(match.range))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let quotationOrLiteralPattern = #"[\"“”`«»]|^\s*quote\b|\b(?:verbatim|literal|exact\s+(?:words|sentence|phrase)|quoted\s+(?:text|words?|sentence|phrase|instruction|request|message|literal|content|term))\b"#
    private static let sourceFreeModifierPatterns = [
        #"^\s*(?:(?:please\s+)?include|put|use)\s+https?://\S+\s+(?:exactly\s+)?in\s+(?:my|the|an?|this)\s+(?:message|update|note|reply)(?:\s+to\s+\p{Lu}[\p{L}-]*)?[.!?]*\s*$"#,
        #"^\s*use\s+the\s+exact\s+phrase\s+[\"“][^\"”\r\n]{1,120}[\"”]\s+in\s+(?:my|the|an?|this)\s+(?:update|note)[.!?]*\s*$"#,
        #"^\s*(?:include|put)\s+the\s+(?:exact\s+)?phrase\s+[\"“][^\"”\r\n]{1,120}[\"”]\s+in\s+my\s+(?:update|note)(?:\s+to\s+\p{Lu}[\p{L}-]*)?[.!?]*\s*$"#,
        #"^\s*add\s+the\s+exact\s+phrase\s+[\"“][^\"”\r\n]{1,120}[\"”]\s+to\s+my\s+(?:status\s+)?update(?:\s+to\s+\p{Lu}[\p{L}-]*)?[.!?]*\s*$"#
    ]
    private static let standaloneSummaryPattern = #"^(?:please\s+)?(?:summarize|sum\s+up)\s+(?:this|that|it)(?:\s+(?:in\s+(?:one|two|three|a\s+single)\s+sentences?|briefly))?[.!?]*\s*$"#
    private static let standaloneContextReplyPattern = #"^\s*(?:(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?(?:reply|respond|answer)\s+to\s+|(?:please\s+)?(?:write|draft|compose)\s+(?:a\s+)?(?:reply|response)\s+to\s+)(?:this|that|it)(?:\s+(?:message|chat|thread))?[.!?]*\s*$"#
    private static let standaloneUncountedBulletsPattern = #"^\s*(?:please\s+)?(?:turn\s+(?:this|that|it)\s+into|put\s+(?:this|that|it)\s+in|format\s+(?:this|that|it)\s+as)\s+(?:bullet\s+points?|bullets?)[.!?]*\s*$"#
    private static let adjective = #"(?:formal|casual|polite|professional|polished|warm|warmer|friendly|friendlier|upbeat|concise|short|shorter|brief)"#
    private static let adverb = #"(?:formally|casually|politely|professionally|concisely)"#
    private static let styleCommand = #"(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?(?:(?:write|rewrite|phrase|say)\s+(?:this|that|it)\s+(?:"#
        + adverb + #"|in\s+(?:a\s+)?"# + adjective + #"\s+(?:tone|style))|(?:make|keep)\s+(?:this|that|it|the\s+prompt)\s+(?:more\s+)?"# + adjective + #"(?:\s+and\s+(?:more\s+)?"# + adjective + #")*(?:\s+and\s+do\s+not\s+give\s+a\s+reason)?|make\s+(?:this|that|it)\s+(?:a\s+)?(?:concise|short)\s+prompt)(?:\s+please)?"#
    private static let replyCommand = #"(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?(?:write|rewrite|draft|compose|phrase)\s+(?:this|that|it)\s+as\s+(?:a\s+)?(?:reply|response|message)(?:\s+(?:in|on|for)\s+(?:this\s+(?:chat|thread)|[\p{L}\p{N}][\p{L}\p{N}_-]*))?(?:\s+please)?"#
    private static let bulletCommand = #"(?:(?:can|could|would)\s+you\s+)?(?:please\s+)?(?:put\s+(?:this|that|it)\s+in|turn\s+(?:this|that|it)\s+into|format\s+(?:this|that|it)\s+as)\s+(?:one|two|three|1|2|3)\s+(?:bullets?|bullet\s+points?)(?:\s+please)?"#
    private static let clarityCommand = #"(?:please\s+)?write\s+this\s+clearly(?:\s+please)?"#
    private static let command = "(?:" + styleCommand + "|" + replyCommand + "|" + bulletCommand + "|" + clarityCommand + ")"
    private static let replyPattern = try! NSRegularExpression(pattern: "^(" + replyCommand + ")$", options: .caseInsensitive)
    private static let leadingPattern = try! NSRegularExpression(pattern: "^(" + command + #")[.!?]\s+"#, options: .caseInsensitive)
    private static let leadingBulletsPattern = try! NSRegularExpression(pattern: "^(" + bulletCommand + #"):\s+"#, options: .caseInsensitive)
    private static let trailingPattern = try! NSRegularExpression(pattern: #"(?:[.!?]\s+|\n+)("# + command + #")[.!?]*\s*$"#, options: .caseInsensitive)
    private static let unpunctuatedFormalGreetingPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:hey|hi|hello)[,!]?\s+)?how(?:(?:['’]s|\s+is)\s+it\s+going|\s+are\s+you)\s+(write\s+this\s+formally)[.!?]*\s*$"#,
        options: .caseInsensitive
    )
    private static let wholeCommandPattern = try! NSRegularExpression(pattern: "^(" + command + #")[.!?]*\s*$"#, options: .caseInsensitive)
    private static let tellRecipientPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(?:to\s+(.+)|((?:[Ii]|[Ww]e|[Tt]he|[Tt]hat)\b.+))\s*$"#
    )
    private static let tellStatusOrNegativeRecipientPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+((?:(?:[Tt]icket|[Ii]ssue|[Cc]ase)|[Dd]o\s+[Nn]ot)\s+\S[^\r\n]*)\s*$"#
    )
    private static let tellNamedNegativeToPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+not\s+to\s+(\S[^\r\n]*)\s*$"#
    )
    private static let draftMessageRecipientPattern = try! NSRegularExpression(
        pattern: #"^[Dd]raft\s+a\s+(?:message|note)\s+to\s+(\p{Lu}[\p{L}-]*)\s+saying\s+(.+)\s*$"#
    )
    private static let namedReplyRecipientPattern = try! NSRegularExpression(
        pattern: #"^[Rr]eply\s+to\s+(\p{Lu}[\p{L}-]*)\s*:\s*(\S[^\r\n]*)$"#
    )
    private static let namedResponseRecipientPattern = try! NSRegularExpression(
        pattern: #"^[Ww]rite\s+this\s+as\s+a\s+response\s+to\s+(\p{Lu}[\p{L}-]*)\s*:\s*(\S[^\r\n]*)$"#
    )
    private static let askNamedRecipientPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+to\s+(.+)\s*$"#
    )
    private static let askCodingAgentPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+the\s+coding\s+agent\s+(to|why)\s+(.+)\s*$"#,
        options: .caseInsensitive
    )
    private static let leadingConversationalSetupPattern = try! NSRegularExpression(
        pattern: #"^Okay,\s+can\s+you\s+help(?:\s+me)?\s+with\s+this\?\s+"#,
        options: .caseInsensitive
    )
}
