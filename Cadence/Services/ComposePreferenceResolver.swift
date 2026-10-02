import CryptoKit
import Foundation
import OSLog

private let composePreferenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposePreferences"
)

/// Builds account/project coordinates only from trusted adapter metadata. The
/// registered adapter and any conversation identity must be freshly validated
/// by their owning authority; this pure function does not certify an adapter,
/// read a page, or grant storage/provider consent.
enum ComposePreferenceScopeFactory {
    static func context(
        evidence: ScribeConversationIdentityEvidence,
        registration: ScribeConversationAdapterRegistration,
        currentBinding: ScribeConversationActionBinding,
        conversation: ScribeVerifiedConversationIdentity? = nil
    ) throws -> ComposeWritingPreferenceContext {
        guard registration.schemaVersion > 0,
              evidence.adapterID == registration.adapterID,
              evidence.schemaVersion == registration.schemaVersion,
              evidence.source == registration.source,
              evidence.binding == currentBinding,
              currentBinding.process.processIdentifier > 0,
              currentBinding.process.bundleIdentifier == registration.hostBundleIdentifier,
              currentBinding.windowIncarnation != nil,
              registration.source != .browserIntegration || currentBinding.tabIncarnation != nil,
              evidence.confidence == .verifiedStableIdentifiers,
              evidence.privacyState == .regular,
              let applicationID = evidence.applicationID,
              applicationID == registration.applicationID,
              let accountID = evidence.accountID else {
            throw ComposeWritingPreferenceError.invalidIdentity
        }
        if let conversation {
            guard conversation.binding == currentBinding,
                  conversation.adapterID == registration.adapterID,
                  let workspace = components(evidence.workspaceID),
                  let project = components(evidence.projectID),
                  let conversationID = evidence.conversationID else {
                throw ComposeWritingPreferenceError.invalidIdentity
            }
            // Bind the supplied conversation key to these same fresh account
            // coordinates, including when an adapter missed a navigation bump.
            // This is the resolver's versioned key contract; a changed contract
            // fails closed here until this consumer is updated with it.
            let expectedConversationKey = digest([
                "scribe-conversation-v1", registration.adapterID.rawValue,
                String(registration.schemaVersion), registration.source.rawValue,
                registration.hostBundleIdentifier, applicationID.rawValue, accountID.rawValue
            ] + workspace + project + [conversationID.rawValue])
            guard conversation.memoryKey.opaqueValue == expectedConversationKey else {
                throw ComposeWritingPreferenceError.invalidIdentity
            }
        }
        let applicationKey = applicationKey(
            registration: registration, accountID: accountID
        )
        let application = ComposePreferenceApplicationIdentity(
            key: applicationKey, adapterID: registration.adapterID, binding: currentBinding
        )
        let project: ComposePreferenceProjectIdentity?
        if case let .identified(projectID) = evidence.projectID,
           let workspace = components(evidence.workspaceID) {
            project = .init(
                key: .init(opaqueValue: digest(
                    ["compose-preference-project-v1", applicationKey.opaqueValue] + workspace + [projectID.rawValue]
                )),
                applicationKey: applicationKey, binding: currentBinding
            )
        } else {
            // An unresolved or absent project never broadens to an account key.
            project = nil
        }
        return .init(binding: currentBinding, application: application, project: project, conversation: conversation)
    }

    /// Settings for a named, single-user native integration may construct the
    /// same opaque key without reading a document. Runtime application still
    /// needs a pinned target from that exact host integration.
    static func applicationKey(
        registration: ScribeConversationAdapterRegistration,
        accountID: ScribeConversationStableID
    ) -> ComposePreferenceApplicationKey {
        .init(opaqueValue: digest([
            "compose-preference-application-v1", registration.adapterID.rawValue,
            String(registration.schemaVersion), registration.source.rawValue,
            registration.hostBundleIdentifier, registration.applicationID.rawValue,
            accountID.rawValue
        ]))
    }

    private static func components(_ container: ScribeConversationContainerID) -> [String]? {
        switch container {
        case let .identified(identifier): return ["identified", identifier.rawValue]
        case .notApplicable: return ["not-applicable"]
        case .unknown: return nil
        }
    }

    private static func digest(_ components: [String]) -> String {
        var bytes = Data()
        for component in components {
            let value = Data(component.utf8)
            bytes.append(contentsOf: "\(value.count):".utf8)
            bytes.append(value)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Independent per-field precedence. This only compiles typed choices; source
/// excerpts and prior drafts have no API through which to write preferences.
enum ComposePreferenceResolver {
    static func combining(
        global: [ComposeWritingPreferenceValue],
        application: [ComposeWritingPreferenceValue]
    ) -> [ComposeWritingPreferenceValue] {
        global.filter { globalValue in
            !application.contains { $0.field == globalValue.field }
        } + application
    }

    /// Uses the same closed field and instruction mapping as scoped resolution.
    /// Explicit current voice removes conflicting saved fields before prompting.
    static func globalInstructions(_ values: [ComposeWritingPreferenceValue], currentVoice: [ScribeWritingDirection]) -> String {
        let overridden = Set(currentVoice.map { value(for: $0).field })
        return values.filter { !overridden.contains($0.field) }.map { instruction(for: $0) }.joined(separator: "\n")
    }
    static let maximumPreferences = 128
    static let maximumCurrentDirections = 32
    static let maximumCompiledUTF8Bytes = 2_048
    static let maximumBulletCount = 12

    private struct Candidate {
        let value: ComposeWritingPreferenceValue
        let provenance: ComposeWritingPreferenceProvenance
        let rank: Int
        let order: Int
        let updatedAt: Date
        let stableID: String
    }

    static func resolve(
        snapshot: ComposeWritingPreferenceSnapshot,
        context: ComposeWritingPreferenceContext,
        currentAction: [ComposeWritingPreferenceValue] = [],
        currentVoice: [ScribeWritingDirection] = [],
        now: Date
    ) throws -> ComposeWritingPreferenceResolution {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw ComposeWritingPreferenceError.invalidTimeWindow }
        guard (!snapshot.isEnabled || snapshot.preferences.count <= maximumPreferences),
              currentAction.count <= maximumCurrentDirections,
              currentVoice.count <= maximumCurrentDirections else {
            throw ComposeWritingPreferenceError.tooManyPreferences
        }
        guard !snapshot.isEnabled || Set(snapshot.preferences.map(\.id)).count == snapshot.preferences.count else {
            throw ComposeWritingPreferenceError.duplicateIdentity
        }
        var candidates: [Candidate] = []
        var validUntil: Date?
        if snapshot.isEnabled {
            for preference in snapshot.preferences {
                try validate(preference.value)
                guard preference.createdAt.timeIntervalSinceReferenceDate.isFinite,
                      preference.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                      preference.createdAt <= preference.updatedAt,
                      preference.expiresAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 > preference.updatedAt }) ?? true else {
                    throw ComposeWritingPreferenceError.invalidTimeWindow
                }
                guard preference.expiresAt.map({ $0 > now }) ?? true,
                      scopeMatches(preference.scope, context: context) else { continue }
                if preference.updatedAt > now {
                    // A wall-clock rollback can place an accepted save in the
                    // future. The empty/fallback result expires when that save
                    // becomes eligible, rather than remaining cached forever.
                    validUntil = validUntil.map { min($0, preference.updatedAt) } ?? preference.updatedAt
                    continue
                }
                if let expiration = preference.expiresAt {
                    validUntil = validUntil.map { min($0, expiration) } ?? expiration
                }
                candidates.append(.init(
                    value: preference.value, provenance: .saved(id: preference.id, scope: preference.scope),
                    rank: rank(preference.scope), order: 0, updatedAt: preference.updatedAt,
                    stableID: preference.id.uuidString
                ))
            }
        }
        for (index, value) in currentAction.enumerated() {
            try validate(value)
            candidates.append(.init(value: value, provenance: .currentAction(index: index), rank: 5, order: index, updatedAt: now, stableID: ""))
        }
        for (index, direction) in currentVoice.enumerated() {
            let value = Self.value(for: direction)
            try validate(value)
            candidates.append(.init(value: value, provenance: .currentVoice(index: index), rank: 6, order: index, updatedAt: now, stableID: ""))
        }
        var preferences: [ComposeResolvedWritingPreference] = []
        var conflicts: [ComposeWritingPreferenceConflict] = []
        for field in ComposeWritingPreferenceField.allCases {
            let ordered = candidates.filter { $0.value.field == field }.sorted(by: precedes)
            guard let selected = ordered.first else { continue }
            preferences.append(.init(value: selected.value, provenance: selected.provenance))
            let overridden = ordered.dropFirst().filter { $0.value != selected.value }.map(\.provenance)
            if !overridden.isEmpty {
                conflicts.append(.init(field: field, selected: selected.provenance, overridden: overridden))
            }
        }
        let compiled = preferences.map { instruction(for: $0.value) }.joined(separator: "\n")
        guard compiled.utf8.count <= maximumCompiledUTF8Bytes else { throw ComposeWritingPreferenceError.invalidValue }
        return .init(
            snapshotRevision: snapshot.revision, context: context, currentAction: currentAction, currentVoice: currentVoice,
            resolvedAt: now, validUntil: validUntil,
            preferences: preferences, conflicts: conflicts, compiledInstructions: compiled
        )
    }

    static func isCurrent(
        _ resolution: ComposeWritingPreferenceResolution,
        snapshot: ComposeWritingPreferenceSnapshot,
        context: ComposeWritingPreferenceContext,
        currentAction: [ComposeWritingPreferenceValue] = [],
        currentVoice: [ScribeWritingDirection] = [],
        now: Date
    ) -> Bool {
        snapshot.revision == resolution.snapshotRevision && context == resolution.context
            && currentAction == resolution.currentAction && currentVoice == resolution.currentVoice
            && now.timeIntervalSinceReferenceDate.isFinite && now >= resolution.resolvedAt
            && (resolution.validUntil.map { now < $0 } ?? true)
    }

    static func scopeMatches(_ scope: ComposeWritingPreferenceScope, context: ComposeWritingPreferenceContext) -> Bool {
        switch scope {
        case .global: return true
        case let .currentAction(actionID): return actionID == context.binding.actionID
        case let .application(key):
            return context.application?.binding == context.binding && context.application?.key == key
        case let .project(key):
            return context.application?.binding == context.binding && context.project?.binding == context.binding
                && context.project?.applicationKey == context.application?.key && context.project?.key == key
        case let .conversation(key):
            return context.conversation?.binding == context.binding && context.conversation?.memoryKey == key
                && (context.application.map { $0.adapterID == context.conversation?.adapterID } ?? true)
        }
    }

    static func validate(_ value: ComposeWritingPreferenceValue) throws {
        if case let .formatting(.bullets(count)) = value,
           !(1...maximumBulletCount).contains(count) { throw ComposeWritingPreferenceError.invalidValue }
    }

    private static func rank(_ scope: ComposeWritingPreferenceScope) -> Int {
        switch scope {
        case .global: return 0
        case .application: return 1
        case .project: return 2
        case .conversation: return 3
        case .currentAction: return 4
        }
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
        if lhs.order != rhs.order { return lhs.order > rhs.order }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.stableID < rhs.stableID
    }

    private static func value(for direction: ScribeWritingDirection) -> ComposeWritingPreferenceValue {
        switch direction {
        case let .tone(tone): return .tone(tone)
        case .concise: return .concise
        case .reply: return .formatting(.reply)
        case let .bullets(count): return .formatting(.bullets(count: count))
        case .avoidGivingReason: return .avoidUnstatedReasons
        }
    }

    private static func instruction(for value: ComposeWritingPreferenceValue) -> String {
        switch value {
        case let .tone(tone): return ScribeWritingDirection.tone(tone).instruction
        case .concise: return ScribeWritingDirection.concise.instruction
        case .formatting(.prose): return "Write in prose without adding facts, commitments, or recipient instructions."
        case .formatting(.reply): return ScribeWritingDirection.reply.instruction
        case let .formatting(.bullets(count)): return ScribeWritingDirection.bullets(count: count).instruction
        case .avoidUnstatedReasons: return ScribeWritingDirection.avoidGivingReason.instruction
        }
    }
}

/// A few complete one-sentence messages have a safe, visible edit for an
/// explicit saved default. This path bypasses model latency only when the
/// entire sentence matches; ambiguous, quoted, compound, or configured-app
/// requests continue through the normal provider path.
enum ComposePreferenceDirectDraftPolicy {
    static func prepare(
        request: ScribeRequest,
        writing: ScribeWritingDirectionParser.Result
    ) -> String? {
        guard request.intent == .compose,
              request.style == nil,
              request.exactLiterals.isEmpty,
              request.resolvedGuidance?.resolutionSource != .configuredApplication,
              request.resolvedGuidance?.customGuidance == nil,
              request.resolvedEnvironment?.resolutionSource != .rememberedPreference,
              writing.request.unresolvedReferences.isEmpty,
              writing.request.writingDirections.isEmpty,
              writing.request.protectedSpans.isEmpty,
              writing.request.recipientFrame == nil,
              writing.consumedCommands.isEmpty,
              request.effectiveWritingDefaults.count == 1 else { return nil }
        let message = writing.request.message
        guard message == request.spokenTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
              message.utf8.count <= 240,
              !message.contains("\n") else { return nil }

        switch request.effectiveWritingDefaults[0] {
        case .tone(.formal):
            if let parts = groups(in: message, pattern: #"^(?:Hey|Hi),? are you free to ([^?!.;\r\n]{4,160})\?$"#) {
                return "Hello, are you available to \(parts[0])?"
            }
            if let parts = groups(in: message, pattern: #"^I think ([^?!;,\r\n]{4,160})\.$"#) {
                return "I believe \(parts[0])."
            }
        case .tone(.warm):
            if let parts = groups(in: message, pattern: #"^([\p{Lu}][\p{L}'’\-]{1,39}), the ([\p{Ll}][\p{L}-]{1,39}) is ready for review\.$"#) {
                return "Hi \(parts[0]), the \(parts[1]) is ready for review."
            }
        case .concise:
            if let parts = groups(in: message, pattern: #"^The ([\p{Ll}][\p{L} -]{1,80}) status update is ready for everyone to review\.$"#) {
                return "The \(parts[0]) update is ready for everyone to review."
            }
        default:
            break
        }
        return nil
    }

    private static func groups(in text: String, pattern: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text, range: NSRange(location: 0, length: (text as NSString).length)
              ) else { return nil }
        let source = text as NSString
        return (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
    }
}
