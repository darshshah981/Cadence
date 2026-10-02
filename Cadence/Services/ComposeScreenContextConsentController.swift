import Foundation
import OSLog

private let composeScreenConsentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeScreenConsent"
)

enum ComposeScreenContextConsentError: Error, Equatable {
    case invalidAction
    case ineligibleSurface
    case captureNotApproved
    case providerMismatch
}

/// One Compose action owns one short-lived screen-context decision. Capture,
/// local OCR, and provider transmission remain distinct. Only explicit UI
/// confirmation should call the approval methods; construction grants nothing.
@MainActor
final class ComposeScreenContextConsentController {
    static let grantLifetime: TimeInterval = 180

    private struct Active {
        let action: ScribeContextActionBinding
        let capture: ScribeContextSnapshot
        let expiresAt: Date
        var revision: UUID
        var captureGrantID: UUID?
        var transmission: (id: UUID, provider: ScribeContextProviderBinding)?
    }

    private let actionIsCurrent: @MainActor (UUID) -> Bool
    private let captureIsCurrent: @MainActor (ScribeContextSnapshot) -> Bool
    private let providerIsCurrent: @MainActor (ScribeContextProviderBinding) -> Bool
    private let now: @MainActor () -> Date
    private var active: Active?

    init(
        actionIsCurrent: @escaping @MainActor (UUID) -> Bool = { _ in false },
        captureIsCurrent: @escaping @MainActor (ScribeContextSnapshot) -> Bool = { _ in false },
        providerIsCurrent: @escaping @MainActor (ScribeContextProviderBinding) -> Bool = { _ in false },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.actionIsCurrent = actionIsCurrent
        self.captureIsCurrent = captureIsCurrent
        self.providerIsCurrent = providerIsCurrent
        self.now = now
    }

    func begin(
        actionID: UUID,
        capture: ScribeContextSnapshot,
        eligibility: ScribeContextSurfaceEligibility
    ) throws {
        active = nil
        guard eligibility == .eligible else { throw ComposeScreenContextConsentError.ineligibleSurface }
        guard actionIsCurrent(actionID), captureIsCurrent(capture),
              capture.id == capture.applicationTarget.id,
              capture.applicationTarget.source == .scribeAccessibility,
              capture.target.processIdentifier == capture.applicationTarget.process.processIdentifier,
              capture.target.bundleIdentifier == capture.applicationTarget.process.bundleIdentifier,
              capture.target.processIdentifier > 0,
              capture.target.bundleIdentifier?.isEmpty == false else {
            throw ComposeScreenContextConsentError.invalidAction
        }
        let instant = now()
        guard instant.timeIntervalSinceReferenceDate.isFinite else {
            throw ComposeScreenContextConsentError.invalidAction
        }
        active = Active(
            action: .init(actionID: actionID, captureID: capture.id,
                          target: capture.target, opaqueSurfaceID: nil,
                          eligibility: eligibility),
            capture: capture,
            expiresAt: instant.addingTimeInterval(Self.grantLifetime),
            revision: UUID(), captureGrantID: nil, transmission: nil
        )
    }

    /// Called only after the person confirms the one-action local OCR disclosure.
    func approveLocalOCR(actionID: UUID, capture: ScribeContextSnapshot) throws {
        guard isCurrent(actionID: actionID, capture: capture), var active else {
            throw ComposeScreenContextConsentError.invalidAction
        }
        active.captureGrantID = UUID()
        active.transmission = nil
        active.revision = UUID()
        self.active = active
    }

    /// A separate, recipient-specific confirmation. The existing provider
    /// consent receipt and runtime dispatch authorization are still required.
    func approveProviderUse(
        actionID: UUID,
        capture: ScribeContextSnapshot,
        provider: ScribeContextProviderBinding,
        destination: ScribeEgressDestination
    ) throws {
        guard isCurrent(actionID: actionID, capture: capture), var active else {
            throw ComposeScreenContextConsentError.invalidAction
        }
        guard active.captureGrantID != nil else {
            throw ComposeScreenContextConsentError.captureNotApproved
        }
        guard provider.recipientOrigin == destination.recipientOrigin,
              provider.providerDisclosureRevision == destination.disclosureVersion,
              !provider.recipientOrigin.isEmpty,
              providerIsCurrent(provider) else {
            throw ComposeScreenContextConsentError.providerMismatch
        }
        active.transmission = (UUID(), provider)
        active.revision = UUID()
        self.active = active
    }

    func policy(actionID: UUID, capture: ScribeContextSnapshot) -> ScribeContextPolicySnapshot {
        guard isCurrent(actionID: actionID, capture: capture),
              let active, let captureGrantID = active.captureGrantID,
              let bundleID = capture.target.bundleIdentifier else { return .init() }
        let window = ScribeContextGrantWindow(
            acceptedAt: active.expiresAt.addingTimeInterval(-Self.grantLifetime),
            expiresAt: active.expiresAt
        )
        let scope = ScribeContextAccessScope.application(bundleIdentifier: bundleID)
        var policy = ScribeContextPolicySnapshot(
            revision: active.revision, isEnabled: true,
            captureGrants: [.init(id: captureGrantID, scope: scope,
                                  categories: [.screenshot], window: window)]
        )
        if let transmission = active.transmission,
           providerIsCurrent(transmission.provider) {
            policy.transmissionGrants = [.init(
                id: transmission.id, scope: scope,
                provider: transmission.provider, categories: [.screenText],
                contextDisclosureRevision: ScribeContextTransmissionGrant.currentContextDisclosureRevision,
                window: window
            )]
        }
        return policy
    }

    func approvedForPicker(actionID: UUID, capture: ScribeContextSnapshot) -> Bool {
        isCurrent(actionID: actionID, capture: capture) && active?.captureGrantID != nil
    }

    func revoke(actionID: UUID? = nil) {
        guard actionID == nil || active?.action.actionID == actionID else { return }
        if active != nil { composeScreenConsentLogger.debug("Screen context consent cleared") }
        active = nil
    }

    private func isCurrent(actionID: UUID, capture: ScribeContextSnapshot) -> Bool {
        guard let active,
              active.action.actionID == actionID,
              active.action.captureID == capture.id,
              active.capture == capture,
              actionIsCurrent(actionID), captureIsCurrent(capture),
              now() < active.expiresAt else { return false }
        return true
    }
}
