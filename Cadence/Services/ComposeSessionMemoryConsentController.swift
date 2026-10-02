import Foundation
import OSLog

private let composeSessionMemoryConsentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeSessionMemoryConsent"
)

/// Issues only local TextEdit session-memory grants. Selected-text permission
/// is deliberately unrelated, and no provider transmission grant is issued.
@MainActor
final class ComposeSessionMemoryConsentController {
    private(set) var preferences: ComposeSessionMemoryPreferences
    private(set) var policy = ScribeContextPolicySnapshot()
    private(set) var localUseRevision = UUID()
    private let enabled: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    init(
        preferences: ComposeSessionMemoryPreferences = .init(),
        enabled: @escaping @MainActor () -> Bool = { false },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.enabled = enabled
        self.now = now
        rebuildPolicy()
    }

    func updatePreferences(_ preferences: ComposeSessionMemoryPreferences) {
        guard self.preferences != preferences else { return }
        let retentionAuthorityChanged =
            self.preferences.isEnabled != preferences.isEnabled
                || self.preferences.textEditAllowed != preferences.textEditAllowed
                || self.preferences.rememberExplicitFacts != preferences.rememberExplicitFacts
                || self.preferences.rememberChosenDrafts != preferences.rememberChosenDrafts
                || self.preferences.disclosureRevision != preferences.disclosureRevision
        if self.preferences.useFactsInLocalDrafts != preferences.useFactsInLocalDrafts {
            localUseRevision = UUID()
        }
        self.preferences = preferences
        if retentionAuthorityChanged { rebuildPolicy() }
        composeSessionMemoryConsentLogger.debug("Session-memory consent changed")
    }

    /// A feature kill switch must revoke active work without deleting the
    /// user's affirmative choices. Rebuild when rollout state changes.
    func refreshRollout() { rebuildPolicy() }

    private func rebuildPolicy() {
        policy = ScribeContextPolicySnapshot()
        guard enabled(), preferences.permitsTextEditUse else { return }
        let scope = ScribeContextAccessScope.application(bundleIdentifier: "com.apple.TextEdit")
        let window = ScribeContextGrantWindow(acceptedAt: now(), expiresAt: .distantFuture)
        policy.isEnabled = true
        let captureCategories: Set<ScribeContextCaptureCategory> = preferences.permitsChosenDraftRetention
            ? [.sessionMemory, .priorDraft] : [.sessionMemory]
        policy.captureGrants = [.init(
            id: UUID(), scope: scope, categories: captureCategories, window: window
        )]
        if preferences.permitsTextEditRetention || preferences.permitsChosenDraftRetention {
            let retentionCategories: Set<ScribeContextDataCategory> = preferences.permitsChosenDraftRetention
                ? [.sessionMemory, .priorDraft] : [.sessionMemory]
            policy.retentionGrants = [.init(
                id: UUID(), scope: scope, categories: retentionCategories,
                destination: .sessionMemory,
                maximumRetentionInterval: ScribeSessionMemoryLimits.inactivityInterval,
                window: window
            )]
        }
    }
}
