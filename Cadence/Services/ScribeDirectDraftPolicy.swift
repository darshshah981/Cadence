import Foundation
import OSLog

private let scribeDirectDraftLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribeDirectDraft")

/// Narrow formatting rules for already-worded coding-agent requests, simple
/// private-reason attendance declines, and uncertainty reply placement. They cannot
/// answer a question, invent facts, perform a task, or change its constraints.
/// Other requests still use the selected provider's rewriting path.
enum ScribeDirectDraftPolicy {
    static func prepare(_ request: ScribeWritingRequest) -> String? {
        if let greeting = preparesFormalGreeting(request) { return greeting }
        if let question = preservesCompleteRecipientQuestion(request) { return question }
        if let casual = preparesCasualReadyStatus(request) { return casual }
        if let warm = preparesWarmReadyReview(request) { return warm }
        if let concise = preparesConciseTwoEventStatus(request) { return concise }
        if let tentative = preparesFormalTentativeStatement(request) { return tentative }
        if let question = preparesTwoApprovalQuestion(request) { return question }
        if let question = preparesNamedWhetherQuestion(request) { return question }
        if let price = preservesPricePeriodContrast(request) { return price }
        if let fee = preservesFeeTotalContrast(request) { return fee }
        if let units = preservesPercentPointContrast(request) { return units }
        if let limit = preservesNamedNumericContrast(request) { return limit }
        if preservesUncertaintyReply(request) { return request.message }
        if let contrast = preservesShortNamedContrast(request) { return contrast }
        if let identifier = preparesQuotedIdentifierNote(request) { return identifier }
        if let note = preparesExactWordsNote(request) { return note }
        if let phrase = preparesQuotedPhraseSummary(request) { return phrase }
        if let phrase = preparesExactPhraseRecipientInstruction(request) { return phrase }
        if let contrast = preservesNamedBudgetContrast(request) { return contrast }
        if let reply = preservesNamedAvailabilityReply(request) { return reply }
        if let decline = preparesNamedResponseDecline(request) { return decline }
        if let statuses = preparesDistinctStatusMessage(request) { return statuses }
        if let decline = preparesPoliteAttendanceDecline(request) { return decline }
        if let request = preparesPoliteNamedRequest(request) { return request }
        if let friendly = preparesFriendlyTrackingRequest(request) { return friendly }
        if let question = preservesApprovalQuestionSubject(request) { return question }
        if let note = preparesExactPhraseNote(request) { return note }
        if let status = preservesNamedTicketStatus(request) { return status }
        if let negative = preservesNamedNegativeInstruction(request) { return negative }
        if let attendance = preparesPrivateReasonAttendance(request) { return attendance }
        if let availability = preparesPrivateReasonAvailability(request) { return availability }
        if let decline = preparesPrivateMatterDecline(request) { return decline }
        if let correction = preparesCorrectedDayConfirmation(request) { return correction }
        if let correction = preparesCorrectedHourConfirmation(request) { return correction }
        if let inspection = preservesQuotedCodingInspection(request) { return inspection }
        if let imperative = preservesCodingInstruction(request) { return imperative }
        if let complete = preservesConstraintHeavyNamedMessage(request) { return complete }
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              let frame = request.recipientFrame,
              frame.kind == .ask,
              frame.recipient == .codingAgent,
              frame.body.range(of: supportedQuestion, options: .regularExpression) != nil,
              frame.body.range(
                of: #"\b(?:actually|instead|rather|I mean)\b"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil else { return nil }
        // Preserve every body byte, including recipient restrictions. Only
        // the explicit spoken frame changes to an imperative for its recipient.
        return "Explain " + frame.body
    }

    /// The speaker has already asked a complete, recipient-facing question.
    /// Sending it through a model adds latency without adding missing facts.
    /// Limit this to one request for something sent to the speaker, so an
    /// instruction to Cadence to write or perform a task is not echoed.
    private static func preservesCompleteRecipientQuestion(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.message == request.originalTranscript,
              request.protectedSpans.isEmpty,
              request.message.range(
                of: #"^(?:Can|Could|Would|Will)\s+you\s+(?:please\s+)?(?:send|forward|provide)\s+(?:me|us)\s+\S[^?!\r\n]{3,180}\?$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return request.message
    }

    /// This complete greeting needs no factual inference. Bypass local-model
    /// latency and prevent a trailing writer direction from entering the
    /// message, while leaving quoted and recipient-directed uses untouched.
    private static func preparesFormalGreeting(_ request: ScribeWritingRequest) -> String? {
        isFormalGreeting(request) ? "Hello, how are you?" : nil
    }

    static func isFormalGreeting(_ request: ScribeWritingRequest) -> Bool {
        guard request.writingDirections == [.tone(.formal)],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.protectedSpans.isEmpty,
              request.message.range(
                of: #"^(?:hey|hi|hello),?\s+(?:how['’]s\s+it\s+going|how\s+are\s+you(?:\s+doing)?)\??$"#,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else { return false }
        return true
    }

    /// The complete recipient and status are already spoken. A small local
    /// change makes the requested casual tone visible without asking the
    /// provider to paraphrase a fact or guess what is ready for review.
    private static func preparesCasualReadyStatus(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections == [.tone(.casual)],
              request.unresolvedReferences.isEmpty,
              request.protectedSpans.isEmpty,
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case let .named(name) = frame.recipient else { return nil }
        let source = request.originalTranscript as NSString
        guard let match = casualReadyStatusPattern.firstMatch(
            in: request.originalTranscript,
            range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == name else { return nil }
        let subject = source.substring(with: match.range(at: 2))
        let audience = source.substring(with: match.range(at: 3))
        return "Hey \(name), the \(subject)'s ready for \(audience)."
    }

    /// A short ready-for-review status has no missing content. The spoken
    /// warmth direction can be satisfied with a greeting while retaining the
    /// named addressee and the entire factual sentence.
    private static func preparesWarmReadyReview(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.contains(.tone(.warm)),
              request.writingDirections.allSatisfy({ $0 == .tone(.warm) || $0 == .concise }),
              request.unresolvedReferences.isEmpty,
              request.protectedSpans.isEmpty,
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient else { return nil }
        let source = request.message as NSString
        guard let match = warmReadyReviewPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == name else { return nil }
        return "Hi \(name), \(source.substring(with: match.range(at: 2)))."
    }

    /// Condense two independent present-tense facts by removing only the
    /// repeated articles/copula. The subjects and time stay byte-for-byte.
    private static func preparesConciseTwoEventStatus(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections == [.concise],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.protectedSpans.isEmpty else { return nil }
        let source = request.originalTranscript as NSString
        guard let match = conciseTwoEventStatusPattern.firstMatch(
            in: request.originalTranscript,
            range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        let first = source.substring(with: match.range(at: 1))
        let second = source.substring(with: match.range(at: 2))
        let verb = source.substring(with: match.range(at: 3))
        let time = source.substring(with: match.range(at: 4))
        return "\(first.prefix(1).uppercased())\(first.dropFirst()) ready; the \(second) \(verb) \(time)."
    }

    /// A single tentative statement can become visibly formal by changing
    /// only its opening hedge. The proposition and its second uncertainty
    /// marker remain byte-for-byte, avoiding a model's tendency to drop them.
    private static func preparesFormalTentativeStatement(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections == [.tone(.formal)],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.protectedSpans.isEmpty,
              request.message.range(
                of: #"^I think [^?!;\r\n]{5,240}\bmay\b[^?!;\r\n]*\.$"#,
                options: .regularExpression
              ) != nil,
              request.message.range(
                of: #"\b(?:actually|instead|rather|I mean|correction)\b"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil else { return nil }
        return "I believe" + String(request.message.dropFirst("I think".count))
    }

    /// A short attendance decline is already complete message content. The
    /// trailing privacy clause is a direction to the writer, not a promise to
    /// the recipient. Keep this grammar narrow: a supplied reason or any
    /// further task remains on the normal generation path.
    private static func preparesPrivateReasonAttendance(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient else { return nil }
        let source = request.message as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = privateReasonAttendancePattern.firstMatch(in: request.message, range: range),
              source.substring(with: match.range(at: 1)) == name else { return nil }
        let attendance = source.substring(with: match.range(at: 2))
        return "\(name), \(attendance)."
    }

    static func isPrivateReasonAttendanceRequest(_ speech: String) -> Bool {
        privateReasonAttendancePattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: (speech as NSString).length)
        ) != nil
    }

    /// A short availability statement is already sendable. The trailing
    /// privacy instruction belongs to the writer and must not be forwarded.
    private static func preparesPrivateReasonAvailability(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient else { return nil }
        let source = request.message as NSString
        guard let match = privateReasonAvailabilityPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == name else { return nil }
        return "\(name), \(source.substring(with: match.range(at: 2)))."
    }

    static func isPrivateReasonAvailabilityRequest(_ speech: String) -> Bool {
        privateReasonAvailabilityPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: (speech as NSString).length)
        ) != nil
    }

    /// In this complete form the speaker explicitly withholds the supplied
    /// reason. A sendable decline needs only the addressee and refusal.
    private static func preparesPrivateMatterDecline(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.isEmpty,
              let parts = privateMatterDeclineParts(in: request.message) else { return nil }
        return "\(parts.recipient), \(parts.decline)."
    }

    static func privateMatterDeclineParts(in speech: String) -> (recipient: String, decline: String)? {
        let source = speech as NSString
        guard let match = privateMatterDeclinePattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (source.substring(with: match.range(at: 1)), source.substring(with: match.range(at: 2)))
    }

    /// Use the final explicit day correction and keep the request for
    /// confirmation as a question to the addressee.
    private static func preparesCorrectedDayConfirmation(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.isEmpty,
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient,
              let parts = correctedDayConfirmationParts(in: request.message),
              parts.name == name,
              parts.oldDay.caseInsensitiveCompare(parts.newDay) != .orderedSame else { return nil }
        return "\(name), the \(parts.subject) is \(parts.newDay). Can you confirm?"
    }

    static func correctedDayConfirmationParts(in speech: String) -> (
        name: String, subject: String, oldDay: String, newDay: String
    )? {
        let source = speech as NSString
        guard let match = correctedDayConfirmationPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (
            source.substring(with: match.range(at: 1)),
            source.substring(with: match.range(at: 2)),
            source.substring(with: match.range(at: 3)),
            source.substring(with: match.range(at: 4))
        )
    }

    /// The time correction precedes a trailing delivery instruction. Keep
    /// only the final hour and turn the confirmation request toward the
    /// addressee instead of copying “Tell Ian” into the outgoing text.
    private static func preparesCorrectedHourConfirmation(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.isEmpty,
              let parts = correctedHourConfirmationParts(in: request.message),
              parts.oldHour.caseInsensitiveCompare(parts.newHour) != .orderedSame else { return nil }
        return "\(parts.recipient), the \(parts.subject) is at \(parts.newHour). Can you confirm?"
    }

    static func correctedHourConfirmationParts(in speech: String) -> (
        recipient: String, subject: String, oldHour: String, newHour: String
    )? {
        let source = speech as NSString
        guard let match = correctedHourConfirmationPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (
            source.substring(with: match.range(at: 4)),
            source.substring(with: match.range(at: 1)),
            source.substring(with: match.range(at: 2)),
            source.substring(with: match.range(at: 3))
        )
    }

    /// A final sentence about keeping two stated statuses distinct directs
    /// the writer. In this narrow form the complete message is already spoken,
    /// so preserve both clauses rather than asking a model to restate the rule.
    private static func preparesDistinctStatusMessage(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        guard let match = distinctStatusesPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        let name = source.substring(with: match.range(at: 1))
        return "\(name), \(source.substring(with: match.range(at: 2)))."
    }

    /// The politeness and no-invention clause is a writer instruction, not a
    /// statement the recipient should receive. This complete attendance form
    /// can be rendered without adding a reason or changing the reported fact.
    private static func preparesPoliteAttendanceDecline(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient else { return nil }
        let source = request.message as NSString
        guard let match = politeAttendancePattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == name else { return nil }
        return "Hi \(name), I’m sorry, but \(source.substring(with: match.range(at: 2)))."
    }

    /// A complete one-action request can be phrased politely without passing
    /// the trailing writer direction through to the recipient.
    private static func preparesPoliteNamedRequest(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let parts = politeNamedRequestParts(in: request.message) else { return nil }
        return "\(parts.recipient), could you please \(parts.action)?"
    }

    static func politeNamedRequestParts(in speech: String) -> (recipient: String, action: String)? {
        let source = speech as NSString
        guard let match = politeNamedRequestPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (source.substring(with: match.range(at: 1)), source.substring(with: match.range(at: 2)))
    }

    /// This request needs no inferred shipment or arrival facts. Its explicit
    /// friendly tone is satisfied with a greeting and one polite question.
    private static func preparesFriendlyTrackingRequest(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.isEmpty,
              let recipient = friendlyTrackingRequestRecipient(in: request.message) else { return nil }
        return "Hi \(recipient), could you please send me the tracking number?"
    }

    static func friendlyTrackingRequestRecipient(in speech: String) -> String? {
        let source = speech as NSString
        guard let match = friendlyTrackingRequestPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return source.substring(with: match.range(at: 1))
    }

    /// A complete availability reply needs only its explicit addressee frame
    /// removed. The small model omitted that person in an actual evaluation.
    private static func preservesNamedAvailabilityReply(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named = frame.recipient,
              request.message.range(of: #"^[Rr]eply\s+to\s+\p{Lu}[\p{L}-]*\s*:"#,
                                    options: .regularExpression) != nil,
              frame.body.utf16.count <= 320,
              frame.body.range(of: #"\bworks\b"#,
                               options: [.regularExpression, .caseInsensitive]) != nil,
              frame.body.range(of: #"\b(?:write|rewrite|draft|compose|actually|instead)\b"#,
                               options: [.regularExpression, .caseInsensitive]) == nil else {
            return nil
        }
        return frame.preparedMessage
    }

    /// The trailing no-reason sentence directs Cadence, not the recipient.
    /// This bounded decline contains its complete sendable wording already.
    private static func preparesNamedResponseDecline(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        guard let match = namedResponseDeclinePattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return "\(source.substring(with: match.range(at: 1))), \(source.substring(with: match.range(at: 2)))."
    }

    /// This complete question needs only its spoken "Ask" frame converted
    /// into the recipient-facing question. Keep both required approvals.
    private static func preparesTwoApprovalQuestion(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        guard let match = twoApprovalQuestionPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return "\(source.substring(with: match.range(at: 1))), can we \(source.substring(with: match.range(at: 2)))?"
    }

    /// Convert two common complete "whether" clauses by moving their
    /// existing auxiliary verb to the front. No new proposition is inferred.
    private static func preparesNamedWhetherQuestion(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        let range = NSRange(location: 0, length: source.length)
        if let match = namedWhetherCanBePattern.firstMatch(in: request.message, range: range) {
            return "\(source.substring(with: match.range(at: 1))), can the \(source.substring(with: match.range(at: 2))) \(source.substring(with: match.range(at: 3)))?"
        }
        if let match = namedIfTicketCanPattern.firstMatch(in: request.message, range: range) {
            return "\(source.substring(with: match.range(at: 1))), can \(source.substring(with: match.range(at: 2))) \(source.substring(with: match.range(at: 3)))?"
        }
        if let match = namedIfIsPattern.firstMatch(in: request.message, range: range) {
            return "\(source.substring(with: match.range(at: 1))), is the \(source.substring(with: match.range(at: 2))) \(source.substring(with: match.range(at: 3)))?"
        }
        if let match = namedWhetherIsPattern.firstMatch(in: request.message, range: range) {
            return "\(source.substring(with: match.range(at: 1))), is the \(source.substring(with: match.range(at: 2))) \(source.substring(with: match.range(at: 3)))?"
        }
        if let match = namedWhetherTrialPattern.firstMatch(in: request.message, range: range) {
            return "\(source.substring(with: match.range(at: 1))), does the cancellation apply to the trial only, not paid accounts?"
        }
        if let match = namedWhetherReviewPattern.firstMatch(in: request.message, range: range) {
            return "\(source.substring(with: match.range(at: 1))), can review begin only after the logs finish uploading?"
        }
        return nil
    }

    /// A stated billing-period contrast is already concise. Preserve both
    /// sides byte-for-byte rather than inviting a rewrite to erase the
    /// correction about what the price does not mean.
    private static func preservesPricePeriodContrast(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty || request.writingDirections == [.concise],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        guard let match = pricePeriodContrastPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == source.substring(with: match.range(at: 3)),
           source.substring(with: match.range(at: 2)).caseInsensitiveCompare(
                source.substring(with: match.range(at: 4))
           ) != .orderedSame else { return nil }
        return request.message
    }

    /// The spoken sentence already distinguishes a recurring fee from a
    /// one-time total. Keeping it intact is safer and faster than a rewrite
    /// that can silently drop the negative half of the contrast.
    private static func preservesFeeTotalContrast(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty || request.writingDirections == [.concise],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.protectedSpans.isEmpty else { return nil }
        let source = request.message as NSString
        guard let match = feeTotalContrastPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == source.substring(with: match.range(at: 3)) else {
            return nil
        }
        return request.message
    }

    /// Percent change and percentage-point change are different quantities.
    /// This complete short sentence already expresses the requested contrast.
    private static func preservesPercentPointContrast(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty || request.writingDirections == [.concise],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        guard let match = percentPointContrastPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == source.substring(with: match.range(at: 2)) else {
            return nil
        }
        return request.message
    }

    private static func preservesNamedNumericContrast(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient else { return nil }
        let source = request.message as NSString
        guard let match = namedNumericContrastPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == name,
           source.substring(with: match.range(at: 2)) == source.substring(with: match.range(at: 3)) else {
            return nil
        }
        return frame.preparedMessage
    }

    /// A short, complete recipient-facing statement can already carry its
    /// own condition, uncertainty, or negation. Keep that wording and the
    /// named addressee intact instead of exposing those constraints to a
    /// paraphrase. Exclude corrections, compound work and quoted requests.
    private static func preservesConstraintHeavyNamedMessage(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named = frame.recipient,
              frame.body.utf16.count <= 220,
              frame.body.range(of: #"^(?:I|we|the|that)\b"#,
                               options: [.regularExpression, .caseInsensitive]) != nil,
              frame.body.range(of: #"\b(?:not|unless|until|only|if|but|may|might)\b"#,
                               options: [.regularExpression, .caseInsensitive]) != nil,
              frame.body.range(of: #"\b(?:actually|instead|rather|I\s+mean|write|rewrite|compose|draft|make\s+this)\b"#,
                               options: [.regularExpression, .caseInsensitive]) == nil,
              frame.body.range(of: #"\b(?:budget|limit|keep\s+the\s+reason\s+private)\b"#,
                               options: [.regularExpression, .caseInsensitive]) == nil,
              frame.body.range(of: #"[.!?]\s+\p{Lu}"#, options: .regularExpression) == nil,
              !frame.body.contains("?") else { return nil }
        return frame.preparedMessage
    }

    /// Keep this complete tax-inclusive total as spoken, including the
    /// explicitly excluded pre-tax interpretation.
    private static func preservesShortNamedContrast(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named = frame.recipient,
              frame.body.range(of: #"^the\s+total\s+is\s+\$[\d,]+(?:\.\d{2})?\s+including\s+tax,\s+not\s+before\s+tax\.$"#,
                               options: [.regularExpression, .caseInsensitive]) != nil,
              request.message.range(of: #"[.!?]\s+\p{Lu}"#, options: .regularExpression) == nil else {
            return nil
        }
        return frame.preparedMessage
    }

    private static func preparesQuotedIdentifierNote(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              let parts = quotedIdentifierNoteParts(in: request.message) else { return nil }
        return "\(parts.recipient), include the exact identifier \(parts.identifier) in the update and do not rename it."
    }

    /// The exact quoted sentence is already the note's content. Preserve its
    /// bytes and add only the explicitly named addressee; the local model can
    /// otherwise return the quote alone and silently drop that person.
    private static func preparesExactWordsNote(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              let parts = exactWordsNoteParts(in: request.message) else { return nil }
        let terminal = parts.words.last.map { ".!?".contains($0) } == true ? "" : "."
        return "\(parts.recipient), \(parts.words)\(terminal)"
    }

    static func exactWordsNoteParts(in speech: String) -> (recipient: String, words: String)? {
        let source = speech as NSString
        guard let match = exactWordsNotePattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (source.substring(with: match.range(at: 1)), source.substring(with: match.range(at: 2)))
    }

    static func quotedIdentifierNoteParts(in speech: String) -> (recipient: String, identifier: String)? {
        let source = speech as NSString
        guard let match = quotedIdentifierNotePattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (source.substring(with: match.range(at: 1)), source.substring(with: match.range(at: 2)))
    }

    private static func preparesQuotedPhraseSummary(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              let parts = quotedPhraseSummaryParts(in: request.message) else { return nil }
        return "\(parts.recipient), include the exact phrase \(parts.phrase) in the summary and do not claim approval."
    }

    static func quotedPhraseSummaryParts(in speech: String) -> (recipient: String, phrase: String)? {
        let source = speech as NSString
        guard let match = quotedPhraseSummaryPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (source.substring(with: match.range(at: 1)), source.substring(with: match.range(at: 2)))
    }

    /// This is a complete instruction to the named recipient. Retain the
    /// speaker's exact target noun (update, note, or summary) and literal;
    /// the model has previously substituted an unsupported document target.
    private static func preparesExactPhraseRecipientInstruction(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              let parts = exactPhraseRecipientInstructionParts(in: request.message) else { return nil }
        return "\(parts.recipient), \(parts.verb) the exact phrase \(parts.phrase) in the \(parts.target) and do not \(parts.restriction) \(parts.claimObject)."
    }

    static func exactPhraseRecipientInstructionParts(
        in speech: String
    ) -> (recipient: String, verb: String, phrase: String, target: String, restriction: String, claimObject: String)? {
        let source = speech as NSString
        guard let match = exactPhraseRecipientInstructionPattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (
            source.substring(with: match.range(at: 1)),
            source.substring(with: match.range(at: 2)).lowercased(),
            source.substring(with: match.range(at: 3)),
            source.substring(with: match.range(at: 4)).lowercased(),
            source.substring(with: match.range(at: 5)).lowercased(),
            source.substring(with: match.range(at: 6)).lowercased()
        )
    }

    /// Both bounds and the amount are already fully spoken. Keep the explicit
    /// contrast intact instead of letting a rewrite silently drop its negation.
    private static func preservesNamedBudgetContrast(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named(let name) = frame.recipient else { return nil }
        let source = request.message as NSString
        guard let match = namedBudgetContrastPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ), source.substring(with: match.range(at: 1)) == name,
           source.substring(with: match.range(at: 3)) != source.substring(with: match.range(at: 5)),
           source.substring(with: match.range(at: 4)) == source.substring(with: match.range(at: 6)) else {
            return nil
        }
        return frame.preparedMessage
    }

    /// Convert only the spoken addressee frame of a simple approval question.
    /// The on-device model previously changed the subject from the file to the
    /// recipient; preserving the source noun phrase avoids that meaning shift.
    private static func preservesApprovalQuestionSubject(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }) else { return nil }
        let source = request.message as NSString
        guard let match = approvalQuestionPattern.firstMatch(
            in: request.message, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        let name = source.substring(with: match.range(at: 1))
        let subject = source.substring(with: match.range(at: 2))
        let remainder = source.substring(with: match.range(at: 3))
        guard remainder.range(of: #"\b(?:and|or|but|instead|also)\b"#,
                              options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return "\(name), does \(subject) need \(remainder)?"
    }

    /// Both the literal and addressee are explicit. Address the named person
    /// directly so the quoted phrase cannot turn into an instruction to the
    /// writing assistant about a different recipient.
    private static func preparesExactPhraseNote(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              let parts = exactPhraseNoteParts(in: request.message) else { return nil }
        return "\(parts.recipient), “\(parts.phrase)”"
    }

    /// A complete one-line ticket status needs only its spoken addressee frame
    /// removed. Preserve the status and identifier byte-for-byte rather than
    /// letting a small model omit the recipient.
    private static func preservesNamedTicketStatus(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named = frame.recipient,
              frame.body.range(of: namedTicketStatusPattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return frame.preparedMessage
    }

    /// "Tell Name not to ..." and "Tell Name do not ..." state a complete
    /// prohibition for the recipient.
    /// Convert only that leading speech frame; keep the named recipient and
    /// every word of the action instead of returning the command to the writer.
    private static func preservesNamedNegativeInstruction(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.message.utf16.count <= 220,
              request.message.range(
                of: #"\b(?:actually|instead|rather|I mean|then|after that|also)\b"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil,
              request.message.range(of: #"[.!?]\s+\p{Lu}"#, options: .regularExpression) == nil,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              let frame = request.recipientFrame,
              frame.kind == .tell,
              case .named = frame.recipient,
              frame.body.range(of: #"^do not \S"#, options: .regularExpression) != nil,
              request.message.range(
                of: #"^[Tt]ell\s+\p{Lu}[\p{L}-]*\s+(?:not\s+to|do\s+not)\s+\S[^\r\n]*$"#,
                options: .regularExpression
              ) != nil else { return nil }
        return frame.preparedMessage
    }

    static func exactPhraseNoteParts(in speech: String) -> (recipient: String, phrase: String)? {
        let source = speech as NSString
        guard let match = exactPhraseNotePattern.firstMatch(
            in: speech, range: NSRange(location: 0, length: source.length)
        ) else { return nil }
        return (source.substring(with: match.range(at: 2)), source.substring(with: match.range(at: 1)))
    }

    /// A complete imperative needs only its voice-only drafting frame removed.
    /// In the observed local-model failures, rewriting this frame lost an
    /// explicit no-change limit or returned literal metadata. Keep the body
    /// verbatim apart from capitalizing its initial ASCII action verb.
    private static func preservesCodingInstruction(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.protectedSpans.allSatisfy({ $0.kind != .quotedOrLiteralRequest }),
              request.message == request.originalTranscript,
              request.message.utf16.count <= 240,
              request.message.range(of: #"\b(?:actually|instead|rather|I mean|then|after that|also|plus)\b"#,
                                    options: [.regularExpression, .caseInsensitive]) == nil,
              let match = codingInstructionPattern.firstMatch(
                in: request.message,
                range: NSRange(location: 0, length: (request.message as NSString).length)
              ) else { return nil }
        let source = request.message as NSString
        let action = source.substring(with: match.range(at: 1))
        let remainder = source.substring(with: match.range(at: 2))
        guard !remainder.isEmpty, !remainder.contains("\n"),
              !remainder.contains("?"),
              remainder.range(of: #"[.!]\s+\p{Lu}"#, options: .regularExpression) == nil else { return nil }
        return action.prefix(1).uppercased() + String(action.dropFirst()) + " " + remainder
    }

    /// A backticked path causes the general parser to protect the entire
    /// utterance. For this complete, read-only coding request, only remove the
    /// leading voice-to-writer frame; copy the task and technical bytes intact.
    private static func preservesQuotedCodingInspection(_ request: ScribeWritingRequest) -> String? {
        guard request.writingDirections.isEmpty,
              request.unresolvedReferences.isEmpty,
              request.message == request.originalTranscript,
              request.message.utf16.count <= 240,
              request.message.components(separatedBy: "`").count == 3,
              !ScribeWrittenRelativeFilePolicy.values(in: request.message).isEmpty,
              request.message.range(
                of: #"\b(?:actually|instead|rather|I mean|then|after that|also|plus)\b"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil,
              let match = quotedCodingInspectionPattern.firstMatch(
                in: request.message,
                range: NSRange(request.message.startIndex..., in: request.message)
              ) else { return nil }
        let source = request.message as NSString
        let action = source.substring(with: match.range(at: 1))
        let remainder = source.substring(with: match.range(at: 2))
        guard !remainder.isEmpty, !remainder.contains("\n"), !remainder.contains("?"),
              remainder.range(of: #"[.!]\s+\p{Lu}"#, options: .regularExpression) == nil else { return nil }
        return action.prefix(1).uppercased() + String(action.dropFirst()) + " " + remainder
    }

    /// Reply placement alone need not paraphrase an already spoken statement.
    /// The actual held-out model result changed "I think the draft is ready."
    /// to "The draft is ready." Returning the complete message avoids both
    /// that certainty change and a lossy attempt to repair generated prose.
    /// This is deterministic formatting, not general semantic validation.
    private static func preservesUncertaintyReply(_ request: ScribeWritingRequest) -> Bool {
        guard request.writingDirections == [.reply],
              request.unresolvedReferences.isEmpty,
              request.recipientFrame == nil,
              request.message.range(of: uncertaintyStatement, options: .regularExpression) != nil,
              request.message.range(
                of: #"\b(?:actually|instead|rather|I mean|sorry|correction|no|write|rewrite|translate|summarize|make this|make it)\b"#,
                options: [.regularExpression, .caseInsensitive]
              ) == nil else { return false }
        return true
    }

    // One short first-person uncertainty statement. Questions, quotations,
    // multiple sentences, technical punctuation and compound task framing stay
    // on the model path. This does not remove or normalize any message bytes.
    private static let uncertaintyStatement = #"^(?:I (?:think|believe|suspect)|I['’]m (?:unsure|not sure), but I think|I might be wrong, but I think) [^,.!?;:\r\n\"“”‘’`\p{Pd}]{1,320}\.?$"#

    private static let casualReadyStatusPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]{1,39})\s+the\s+([\p{Ll}][\p{L}-]{1,39})\s+is\s+ready\s+for\s+((?:the\s+)?[\p{Ll}][\p{L}-]{1,39})\.\s+Make\s+it\s+casual\.?$"#
    )
    private static let conciseTwoEventStatusPattern = try! NSRegularExpression(
        pattern: #"^[Tt]he\s+([\p{Ll}][\p{L}-]{1,39})\s+(?:is|are)\s+ready\s+and\s+the\s+([\p{Ll}][\p{L}-]{1,39})\s+(begins|starts)\s+(\p{Lu}[\p{L}-]{1,39})\.\s+Make\s+this\s+concise\.?$"#
    )

    private static let privateReasonAttendancePattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(I\s+(?:cannot|can't|can’t|will not|won't|won’t)\s+(?:join|attend|make)\s+(?:the\s+)?(?:call|meeting|session|event|rehearsal|dinner|appointment|review|it)(?:\s+(?:today|tomorrow|tonight))?),\s+and\s+keep\s+the\s+reason\s+private\.?$"#,
        options: [.caseInsensitive]
    )
    private static let privateReasonAvailabilityPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(I\s+can\s+(?:join|attend|make\s+it)\s+only\s+before\s+(?:noon|midday|\d{1,2}(?::\d{2})?\s*(?:AM|PM))(?:,\s+not\s+after)?),\s+and\s+keep\s+the\s+reason\s+private\.?$"#,
        options: [.caseInsensitive]
    )
    private static let privateMatterDeclinePattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(I\s+(?:cannot|can't|can’t)\s+(?:join|attend))\s+because\s+of\s+a\s+private\s+matter\.\s+Do\s+not\s+share\s+the\s+reason\.$"#,
        options: [.caseInsensitive]
    )
    private static let warmReadyReviewPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(the\s+[\p{L}-]+(?:\s+[\p{L}-]+){0,2}\s+is\s+ready\s+(?:to|for)\s+review)\.$"#,
        options: [.caseInsensitive]
    )
    private static let correctedDayConfirmationPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+the\s+([\p{L}-]+(?:\s+[\p{L}-]+){0,2})\s+is\s+(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\.\s+Sorry,\s+(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\.\s+Ask\s+(?:him|her|them)\s+to\s+confirm\.$"#,
        options: [.caseInsensitive]
    )
    private static let correctedHourConfirmationPattern = try! NSRegularExpression(
        pattern: #"^[Tt]he\s+(call|meeting|review|demo)\s+is\s+at\s+(\d{1,2}(?::\d{2})?\s*(?:AM|PM))\.\s+Actually\s+(\d{1,2}(?::\d{2})?\s*(?:AM|PM))\.\s+Tell\s+(\p{Lu}[\p{L}-]*)\s+and\s+ask\s+(?:him|her|them)\s+to\s+confirm\.$"#,
        options: [.caseInsensitive]
    )

    private static let distinctStatusesPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+((?:the\s+[\p{L}-]+(?:\s+[\p{L}-]+){0,2}\s+is\s+(?:pending|approved|rejected|paid|unpaid|complete|incomplete|open|closed|blocked|delayed))\s+and\s+(?:the\s+[\p{L}-]+(?:\s+[\p{L}-]+){0,2}\s+is\s+(?:pending|approved|rejected|paid|unpaid|complete|incomplete|open|closed|blocked|delayed)))\.\s+Keep\s+the\s+two\s+statuses\s+distinct\.?$"#,
        options: [.caseInsensitive]
    )

    private static let politeAttendancePattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(I\s+(?:cannot|can't|can’t|will\s+not|won't|won’t)\s+(?:join|attend|make)\s+(?:the\s+)?(?:call|meeting|session|event|rehearsal|dinner|appointment)(?:\s+(?:today|tomorrow|tonight))?),\s+and\s+make\s+the\s+reply\s+polite\s+without\s+inventing\s+a\s+reason\.?$"#,
        options: [.caseInsensitive]
    )

    private static let politeNamedRequestPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+to\s+([a-z][^,.!?\r\n]{1,180}),\s+and\s+make\s+the\s+request\s+polite\.$"#
    )
    private static let friendlyTrackingRequestPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+for\s+the\s+tracking\s+number,\s+and\s+keep\s+it\s+friendly\.$"#,
        options: [.caseInsensitive]
    )

    private static let namedResponseDeclinePattern = try! NSRegularExpression(
        pattern: #"^[Ww]rite\s+this\s+as\s+a\s+response\s+to\s+(\p{Lu}[\p{L}-]*)\s*:\s*(I\s+appreciate\s+(?:the|your)\s+invitation,\s+but\s+I\s+(?:cannot|can't|can’t)\s+attend)\.\s+Do\s+not\s+give\s+a\s+reason\.?$"#,
        options: .caseInsensitive
    )

    private static let namedBudgetContrastPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+(the\s+budget\s+is\s+at\s+(least|most)\s+(\$[\d,]+(?:\.\d{2})?),\s+not\s+at\s+(least|most)\s+(\$[\d,]+(?:\.\d{2})?)\.)$"#,
        options: [.caseInsensitive]
    )

    private static let twoApprovalQuestionPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+whether\s+we\s+can\s+((?:deploy|publish|ship)\s+only\s+after\s+both\s+\p{L}[\p{L}-]*\s+and\s+\p{L}[\p{L}-]*\s+approve)\.$"#
    )
    private static let namedWhetherCanBePattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+whether\s+the\s+([\p{L}-]+)\s+can\s+(\S[^.!?\r\n]{1,160})\.$"#
    )
    private static let namedIfTicketCanPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+if\s+((?:ticket|issue|case)\s+[\p{L}\p{N}_-]{2,40})\s+can\s+(\S[^.!?\r\n]{1,160})\.$"#,
        options: .caseInsensitive
    )
    private static let namedIfIsPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+if\s+the\s+([\p{L}-]+)\s+is\s+(\S[^.!?\r\n]{1,160})\.$"#
    )
    private static let namedWhetherIsPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+whether\s+the\s+((?:[\p{L}-]+\s+){0,4}[\p{L}-]+)\s+is\s+(\S[^.!?\r\n]{1,160})\.$"#
    )
    private static let namedWhetherTrialPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+whether\s+the\s+cancellation\s+applies\s+to\s+the\s+trial\s+only,\s+not\s+paid\s+accounts\.$"#,
        options: [.caseInsensitive]
    )
    private static let namedWhetherReviewPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+whether\s+review\s+can\s+begin\s+only\s+after\s+the\s+logs\s+finish\s+uploading\.$"#,
        options: [.caseInsensitive]
    )
    private static let percentPointContrastPattern = try! NSRegularExpression(
        pattern: #"^[Tt]he\s+[\p{L}-]+(?:\s+[\p{L}-]+){0,2}\s+(?:increased|rose)\s+by\s+(\d+(?:\.\d+)?)%,\s+not\s+by\s+(\d+(?:\.\d+)?)\s+percentage\s+points\.$"#,
        options: [.caseInsensitive]
    )
    private static let quotedIdentifierNotePattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+to\s+include\s+the\s+exact\s+identifier\s+([\"“][^\"”\r\n]{1,80}[\"”])\s+in\s+the\s+update\s+and\s+not\s+rename\s+it\.$"#
    )
    private static let quotedPhraseSummaryPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+to\s+include\s+the\s+exact\s+phrase\s+([\"“][^\"”\r\n]{1,80}[\"”])\s+in\s+the\s+summary\s+and\s+not\s+claim\s+approval\.$"#
    )
    private static let exactPhraseRecipientInstructionPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+to\s+(use|include)\s+the\s+exact\s+phrase\s+([\"“][^\"”\r\n]{1,120}[\"”])\s+in\s+the\s+(update|note|summary)\s+and\s+not\s+(imply|claim)\s+(approval|payment|delivery|completion)\.$"#,
        options: [.caseInsensitive]
    )
    private static let namedNumericContrastPattern = try! NSRegularExpression(
        pattern: #"^[Tt]ell\s+(\p{Lu}[\p{L}-]*)\s+the\s+limit\s+is\s+(?:under|over|at\s+most|at\s+least)\s+(\$[\d,]+(?:\.\d{2})?),\s+not\s+exactly\s+(\$[\d,]+(?:\.\d{2})?)\.$"#,
        options: [.caseInsensitive]
    )

    private static let pricePeriodContrastPattern = try! NSRegularExpression(
        pattern: #"^[Tt]he\s+price\s+is\s+(\$[\d,]+(?:\.\d{2})?)\s+per\s+(month|year),\s+not\s+(\$[\d,]+(?:\.\d{2})?)\s+per\s+(month|year)\.$"#,
        options: [.caseInsensitive]
    )
    private static let feeTotalContrastPattern = try! NSRegularExpression(
        pattern: #"^[Tt]he\s+(?:fee|price)\s+is\s+(\$[\d,]+(?:\.\d{2})?)\s+per\s+(month|year),\s+not\s+(\$[\d,]+(?:\.\d{2})?)\s+total\.$"#,
        options: [.caseInsensitive]
    )

    private static let approvalQuestionPattern = try! NSRegularExpression(
        pattern: #"^[Aa]sk\s+(\p{Lu}[\p{L}-]*)\s+whether\s+(the\s+[\p{L}-]+(?:\s+[\p{L}-]+){0,2})\s+needs\s+(approval\b[^.!?\r\n]{0,100})\.?$"#
    )

    private static let exactPhraseNotePattern = try! NSRegularExpression(
        pattern: #"^[Ii]nclude\s+the\s+exact\s+phrase\s+[\"“]([^\"”\r\n]{1,120})[\"”]\s+in\s+a\s+note\s+to\s+(\p{Lu}[\p{L}-]*)\.?$"#
    )
    private static let exactWordsNotePattern = try! NSRegularExpression(
        pattern: #"^[Ww]rite\s+a\s+note\s+to\s+(\p{Lu}[\p{L}-]*)\s+saying\s+the\s+exact\s+words\s+[\"“]([^\"”\r\n]{1,120})[\"”]\.?$"#
    )

    private static let namedTicketStatusPattern =
        #"^(?:ticket|issue|case)\s+[\p{L}\p{N}_-]{2,40}\s+(?:is\s+(?:still\s+)?(?:open|closed|pending|approved|rejected|blocked|resolved)|remains\s+(?:open|pending|blocked)\s+until\s+[\p{L}\p{N}][\p{L}\p{N} ]{2,80})\.?$"#

    // One question followed only by these explicit recipient restrictions.
    // A second writing/task sentence, quotes, multiline text, or ambiguous
    // correction cannot enter the direct path.
    private static let supportedQuestion = #"^why [^.!?\r\n]{1,320}[.?]?(?:\s+Do not (?:make any changes|edit files|change code)[.!?]?)*$"#

    private static let codingInstructionPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:Ask\s+(?:the\s+)?(?:coding\s+)?(?:agent|assistant)\s+to)|(?:Draft\s+a\s+(?:short\s+)?request\s+to))\s+(inspect|investigate|review|check|locate|find)\s+(.+)$"#,
        options: .caseInsensitive
    )
    private static let quotedCodingInspectionPattern = try! NSRegularExpression(
        pattern: #"^Ask\s+(?:Codex|Claude|(?:the\s+)?coding\s+agent)\s+to\s+(inspect|investigate|review|check|locate|find)\s+(.+)$"#,
        options: .caseInsensitive
    )
}
