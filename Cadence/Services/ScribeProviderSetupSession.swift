import Foundation

actor ScribeProviderSetupAttemptFence {
    private var valid = true
    func check() -> Bool { valid }
    func invalidate() { valid = false }
}

@MainActor
final class ScribeProviderSetupSession {
    private(set) var credentialBuffer = ""
    private(set) var modelSearchQuery = ""
    private(set) var selectedModelID: String?
    private(set) var attemptRevision = 0
    private(set) var providerKind: ScribeProviderKind?
    private var validationTask: Task<Void, Never>?
    private var currentFence: ScribeProviderSetupAttemptFence?
    private let consentAuthority: ScribeProviderConsentAuthority
    private let cancelConnectionAttempt: @Sendable () async -> Void

    init(
        consentAuthority: ScribeProviderConsentAuthority,
        cancelConnectionAttempt: @escaping @Sendable () async -> Void = {}
    ) {
        self.consentAuthority = consentAuthority
        self.cancelConnectionAttempt = cancelConnectionAttempt
    }

    func begin(
        providerKind: ScribeProviderKind,
        credential: String,
        operation: @escaping @Sendable (
            _ revision: Int,
            _ credential: String,
            _ attemptFence: @escaping @Sendable () async -> Bool
        ) async -> Void
    ) {
        invalidateValidation()
        self.providerKind = providerKind
        credentialBuffer = credential
        attemptRevision += 1
        let revision = attemptRevision
        let attemptFence = ScribeProviderSetupAttemptFence()
        currentFence = attemptFence
        validationTask = Task { [weak self] in
            await operation(revision, credential, { await attemptFence.check() })
            guard !Task.isCancelled, let self, self.attemptRevision == revision else { return }
        }
    }

    func prepareAttempt(providerKind: ScribeProviderKind, credential: String) -> Int {
        invalidateValidation()
        self.providerKind = providerKind
        credentialBuffer = credential
        attemptRevision += 1
        return attemptRevision
    }

    func completeAttempt(revision: Int) {
        guard attemptRevision == revision else { return }
        credentialBuffer = ""
        validationTask = nil
    }

    func providerSwitched(to providerKind: ScribeProviderKind) async {
        let fence = cancelValidation()
        credentialBuffer = ""
        modelSearchQuery = ""
        selectedModelID = nil
        self.providerKind = providerKind
        attemptRevision += 1
        await fence?.invalidate()
        await cancelConnectionAttempt()
        await consentAuthority.revokeAllEphemeral()
    }

    func dismiss() async {
        let fence = cancelValidation()
        credentialBuffer = ""
        modelSearchQuery = ""
        selectedModelID = nil
        providerKind = nil
        attemptRevision += 1
        await fence?.invalidate()
        await cancelConnectionAttempt()
        await consentAuthority.revokeAllEphemeral()
    }

    func acceptsCallback(revision: Int) -> Bool {
        revision == attemptRevision && validationTask?.isCancelled != true
    }

    func credential(for kind: ScribeProviderKind) throws -> String {
        guard providerKind == kind, !credentialBuffer.isEmpty else {
            throw ScribeProviderConnectionError.staleAttempt
        }
        return credentialBuffer
    }

    func setModelSearchQuery(_ query: String) {
        // Search is session-only; do not allow unbounded UI state to outlive a
        // dismissed setup sheet.
        modelSearchQuery = String(query.prefix(256))
    }

    func selectModel(_ modelID: String?) {
        let normalized = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selectedModelID = normalized.isEmpty ? nil : normalized
    }

    @discardableResult
    private func cancelValidation() -> ScribeProviderSetupAttemptFence? {
        validationTask?.cancel()
        validationTask = nil
        let fence = currentFence
        currentFence = nil
        return fence
    }

    private func invalidateValidation() {
        let fence = cancelValidation()
        Task { await fence?.invalidate() }
    }
}
