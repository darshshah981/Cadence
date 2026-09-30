import Foundation
import OSLog

private let composePersistentMemoryConsentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposePersistentMemoryConsent"
)

/// Separately authorizes local, explicit durable facts for verified TextEdit
/// documents. Construction, preference changes, and rollout refreshes never
/// create a storage domain, read Keychain, or retain content.
@MainActor
final class ComposePersistentMemoryConsentController {
    private(set) var preferences: ComposePersistentMemoryPreferences
    private(set) var policy = ScribeContextPolicySnapshot()
    private(set) var localUseRevision = UUID()
    private let enabled: @MainActor () -> Bool
    private let now: @MainActor () -> Date

    init(
        preferences: ComposePersistentMemoryPreferences = .init(),
        enabled: @escaping @MainActor () -> Bool = { false },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.enabled = enabled
        self.now = now
        rebuildPolicy()
    }

    func updatePreferences(_ preferences: ComposePersistentMemoryPreferences) {
        guard self.preferences != preferences else { return }
        if self.preferences.useFactsInLocalDrafts != preferences.useFactsInLocalDrafts {
            localUseRevision = UUID()
        }
        self.preferences = preferences
        rebuildPolicy()
        composePersistentMemoryConsentLogger.debug("Durable-memory consent changed")
    }

    func refreshRollout() {
        localUseRevision = UUID()
        rebuildPolicy()
    }

    private func rebuildPolicy() {
        policy = ScribeContextPolicySnapshot()
        guard enabled(), preferences.permitsTextEditRetention else { return }
        let scope = ScribeContextAccessScope.application(bundleIdentifier: "com.apple.TextEdit")
        let window = ScribeContextGrantWindow(acceptedAt: now(), expiresAt: .distantFuture)
        policy.isEnabled = true
        policy.captureGrants = [.init(
            id: UUID(), scope: scope,
            categories: [.sessionMemory, .persistentMemory], window: window
        )]
        policy.retentionGrants = [.init(
            id: UUID(), scope: scope,
            categories: [.sessionMemory, .persistentMemory],
            destination: .persistentMemory,
            maximumRetentionInterval: ComposePersistentMemoryPreferences.retentionInterval,
            window: window
        )]
    }
}
