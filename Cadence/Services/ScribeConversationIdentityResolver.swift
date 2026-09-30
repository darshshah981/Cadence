import CryptoKit
import Foundation
import OSLog

private let scribeConversationIdentityLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ScribeConversationIdentityResolver"
)

/// Implementations must be trusted integrations that validate their own source
/// and return already-obtained identity evidence. This seam grants no capture or
/// IPC authority. Never register an adapter based on page/provider instructions.
@MainActor
protocol ScribeConversationIdentityAdapter {
    var registration: ScribeConversationAdapterRegistration { get }
    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence?
}

/// A supported integration captures an action's live surface before the
/// resolver may trust its evidence. Never synthesize this binding from a title
/// or a previous action's memory key.
@MainActor
protocol ScribeConversationBindingCapturing: ScribeConversationIdentityAdapter {
    func captureBinding(actionID: UUID, process: ApplicationProcessIdentity) -> ScribeConversationActionBinding?
}

/// Pure local identity validation. No production adapters are registered by
/// default, and this service performs no OS queries, capture, IO, or storage.
@MainActor
final class ScribeConversationIdentityResolver {
    private struct RegisteredAdapter {
        let registration: ScribeConversationAdapterRegistration
        let adapter: any ScribeConversationIdentityAdapter
    }

    private let adapters: [ScribeConversationStableID: RegisteredAdapter]

    init(adapters: [any ScribeConversationIdentityAdapter] = []) throws {
        var registrations: [ScribeConversationStableID: RegisteredAdapter] = [:]
        for adapter in adapters {
            let registration = adapter.registration
            guard registration.schemaVersion > 0,
                  ScribeConversationStableID(rawValue: registration.hostBundleIdentifier) != nil else {
                throw ScribeConversationAdapterRegistrationError.invalidRegistration
            }
            guard registrations[registration.adapterID] == nil else {
                throw ScribeConversationAdapterRegistrationError.duplicateAdapter
            }
            registrations[registration.adapterID] = .init(registration: registration, adapter: adapter)
        }
        self.adapters = registrations
    }

    func resolve(
        adapterID: ScribeConversationStableID?,
        for binding: ScribeConversationActionBinding
    ) -> ScribeConversationIdentityResolution {
        let temporary = transientIdentity(for: binding)
        guard let adapterID, let registered = adapters[adapterID] else {
            return .unsupported(temporary, reason: .noRegisteredAdapter)
        }
        let registration = registered.registration
        guard registered.adapter.registration == registration else {
            return .unsupported(temporary, reason: .registrationChanged)
        }
        guard binding.process.bundleIdentifier == registration.hostBundleIdentifier,
              binding.process.processIdentifier > 0 else {
            return .unsupported(temporary, reason: .hostApplicationMismatch)
        }
        guard binding.windowIncarnation != nil,
              registration.source != .browserIntegration || binding.tabIncarnation != nil else {
            return .ambiguous(temporary, reason: .missingSurfaceIdentity)
        }
        guard let evidence = registered.adapter.evidence(for: binding) else {
            return .ambiguous(temporary, reason: .missingEvidence)
        }
        guard evidence.adapterID == registration.adapterID,
              evidence.schemaVersion == registration.schemaVersion,
              evidence.source == registration.source else {
            return .unsupported(temporary, reason: .sourceMismatch)
        }
        guard evidence.binding == binding else {
            return .ambiguous(temporary, reason: .actionBindingMismatch)
        }
        guard evidence.privacyState != .privateBrowsing else {
            return .unsupported(temporary, reason: .privateSession)
        }
        guard evidence.privacyState == .regular else {
            return .ambiguous(temporary, reason: .unknownPrivacyState)
        }
        guard evidence.confidence == .verifiedStableIdentifiers else {
            return .ambiguous(temporary, reason: .insufficientConfidence)
        }
        guard let applicationID = evidence.applicationID,
              let accountID = evidence.accountID,
              let conversationID = evidence.conversationID,
              let workspace = containerComponents(evidence.workspaceID),
              let project = containerComponents(evidence.projectID) else {
            return .ambiguous(temporary, reason: .missingStableIdentifiers)
        }
        guard applicationID == registration.applicationID else {
            return .unsupported(temporary, reason: .applicationMismatch)
        }

        // Durable coordinates intentionally exclude process/window/tab/action
        // identity. A freshly verified return to the actual same conversation
        // can recover its key, while pending work still binds to its incarnation.
        let key = ScribeConversationMemoryKey(opaqueValue: digest([
            "scribe-conversation-v1", registration.adapterID.rawValue,
            String(registration.schemaVersion), registration.source.rawValue, registration.hostBundleIdentifier,
            applicationID.rawValue, accountID.rawValue
        ] + workspace + project + [conversationID.rawValue]))
        return .verified(.init(memoryKey: key, adapterID: adapterID, binding: binding))
    }

    /// Call before using earlier capture/retrieval results or committing pending
    /// work. Re-resolving also detects a stable-identity change even if an adapter
    /// incorrectly kept its navigation revision. The caller must supply current
    /// authority-verified process/surface binding; this layer cannot observe it.
    func revalidate(
        _ identity: ScribeVerifiedConversationIdentity,
        for currentBinding: ScribeConversationActionBinding
    ) -> Bool {
        guard identity.binding == currentBinding,
              case let .verified(current) = resolve(adapterID: identity.adapterID, for: currentBinding) else {
            return false
        }
        return current == identity
    }

    private func containerComponents(_ container: ScribeConversationContainerID) -> [String]? {
        switch container {
        case let .identified(identifier): return ["identified", identifier.rawValue]
        case .notApplicable: return ["not-applicable"]
        case .unknown: return nil
        }
    }

    private func transientIdentity(for binding: ScribeConversationActionBinding) -> ScribeTransientConversationIdentity {
        let process = binding.process
        let key = digest([
            "scribe-transient-v1", binding.actionID.uuidString,
            String(process.processIdentifier), process.bundleIdentifier,
            process.bundleURL.absoluteString, process.incarnation.uuidString,
            process.launchDate.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "missing-launch-date",
            binding.windowIncarnation?.uuidString ?? "missing-window",
            binding.tabIncarnation?.uuidString ?? "missing-tab", binding.navigationRevision.uuidString
        ])
        return .init(key: .init(opaqueValue: key), binding: binding)
    }

    private func digest(_ components: [String]) -> String {
        // Length framing avoids delimiter collisions and does not use Swift's
        // randomized Hasher. Keys are stable across local process launches.
        var bytes = Data()
        for component in components {
            let value = Data(component.utf8)
            bytes.append(contentsOf: "\(value.count):".utf8)
            bytes.append(value)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
