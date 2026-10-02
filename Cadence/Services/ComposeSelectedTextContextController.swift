import Foundation

@MainActor
protocol ComposeSelectedTextContextServing: AnyObject {
    var onAccessRevoked: ((UUID) -> Void)? { get set }
    func beginCapture(actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination)
    func selectedText(for actionID: UUID) async -> ComposeContextSnapshot?
    func authorizationIsCurrent(for snapshot: ComposeContextSnapshot) -> Bool
    func compileRewrite(_ request: ScribeRequest, using snapshot: ComposeContextSnapshot,
                        destination: ScribeEgressDestination) throws -> ComposeGroundedCompilation
    func compilationIsCurrent(_ compilation: ComposeGroundedCompilation, using snapshot: ComposeContextSnapshot) -> Bool
    func revalidateSelection(_ snapshot: ComposeContextSnapshot) async -> ComposeSelectionRevalidationOutcome
    func clear(actionID: UUID?)
}

/// Owns one invocation's local source and its grants. No source text is stored
/// in preferences, logs, history, diagnostics, or a cloud request by this type.
@MainActor
final class ComposeSelectedTextContextController: ComposeSelectedTextContextServing {
    var onAccessRevoked: ((UUID) -> Void)?
    private(set) var preferences: ComposeSelectedTextContextPreferences
    private let reader: any ComposeSelectedTextReading
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let now: @MainActor () -> Date
    private var policy = ScribeContextPolicySnapshot()
    private var target: ComposeContentCaptureTarget?
    private var captureTask: Task<ComposeContentCaptureOutcome, Never>?
    private var permissionTask: Task<Void, Never>?
    private var snapshot: ComposeContextSnapshot?
    private lazy var contentService = ComposeContentCaptureService(
        reader: reader,
        policy: { [weak self] in self?.policy ?? .init() },
        permissions: { [weak self] in self?.permissions() ?? .init() },
        currentTarget: { [weak self] in self?.target },
        now: { [weak self] in self?.now() ?? Date() }
    )

    init(
        preferences: ComposeSelectedTextContextPreferences = .init(),
        reader: any ComposeSelectedTextReading = SystemComposeSelectedTextReader(),
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions = { .init() },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.reader = reader
        self.permissions = permissions
        self.now = now
        rebuildPolicy()
    }

    func updatePreferences(_ preferences: ComposeSelectedTextContextPreferences) {
        guard self.preferences != preferences else { return }
        let actionID = target?.action.actionID
        self.preferences = preferences
        clear(actionID: nil)
        rebuildPolicy()
        if let actionID { onAccessRevoked?(actionID) }
    }

    func beginCapture(actionID: UUID, capture: ScribeContextSnapshot, destination: ScribeEgressDestination) {
        clear(actionID: nil)
        guard destination == .legacyLocal, preferences.permitsTextEditCapture,
              ComposeSelectedTextEligibilityPolicy.permits(capture) else { return }
        let action = ScribeContextActionBinding(
            actionID: actionID, captureID: capture.id, target: capture.target,
            opaqueSurfaceID: nil, eligibility: .eligible
        )
        let target = ComposeContentCaptureTarget(action: action, context: capture)
        self.target = target
        let service = contentService
        captureTask = Task { await service.captureSelectedText(from: target) }
        // Poll only a coarse permission bit while an opted-in action exists.
        // This performs no text reads and stops on clear, revocation, or finish.
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.target?.action.actionID == actionID else { return }
                if !self.permissions().accessibility {
                    self.clear(actionID: actionID)
                    self.onAccessRevoked?(actionID)
                    return
                }
            }
        }
    }

    func selectedText(for actionID: UUID) async -> ComposeContextSnapshot? {
        guard target?.action.actionID == actionID else { return nil }
        if let snapshot { return authorizationIsCurrent(for: snapshot) ? snapshot : nil }
        guard let captureTask else { return nil }
        let outcome = await captureTask.value
        guard !Task.isCancelled, target?.action.actionID == actionID else { return nil }
        self.captureTask = nil
        guard case .captured(let snapshot) = outcome,
              authorizationIsCurrent(for: snapshot) else {
            clear(actionID: actionID)
            return nil
        }
        self.snapshot = snapshot
        return snapshot
    }

    func authorizationIsCurrent(for snapshot: ComposeContextSnapshot) -> Bool {
        guard target == snapshot.target, preferences.permitsTextEditCapture else { return false }
        do {
            try ScribeContextPolicy.revalidate(
                snapshot.authorization,
                for: .init(action: snapshot.target.action, operation: .capture(.selectedText)),
                using: policy, permissions: permissions(), at: now()
            )
            return true
        } catch { return false }
    }

    func revalidateSelection(_ snapshot: ComposeContextSnapshot) async -> ComposeSelectionRevalidationOutcome {
        guard authorizationIsCurrent(for: snapshot) else { return .unavailable(.policy(.policyChanged)) }
        return await contentService.revalidateSelectedText(snapshot)
    }

    func compileRewrite(
        _ request: ScribeRequest, using snapshot: ComposeContextSnapshot,
        destination: ScribeEgressDestination
    ) throws -> ComposeGroundedCompilation {
        guard self.snapshot == snapshot, authorizationIsCurrent(for: snapshot) else {
            throw ComposeGroundedCompilationError.sourceChanged
        }
        return try ComposeContextCompiler.compileSelectedRewrite(
            request, snapshot: snapshot, egress: destination, policy: policy,
            permissions: permissions(), now: now()
        )
    }

    func compilationIsCurrent(_ compilation: ComposeGroundedCompilation, using snapshot: ComposeContextSnapshot) -> Bool {
        guard self.snapshot == snapshot, authorizationIsCurrent(for: snapshot) else { return false }
        do {
            try ComposeContextCompiler.revalidateSelectedRewrite(
                compilation, snapshot: snapshot, egress: .legacyLocal, policy: policy,
                permissions: permissions(), now: now()
            )
            return true
        } catch { return false }
    }

    func clear(actionID: UUID?) {
        if let actionID, target?.action.actionID != actionID { return }
        captureTask?.cancel()
        captureTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        snapshot = nil
        target = nil
    }

    private func rebuildPolicy() {
        policy = ScribeContextPolicySnapshot()
        guard preferences.permitsTextEditCapture else { return }
        policy.isEnabled = true
        policy.captureGrants = [.init(
            id: UUID(), scope: .application(bundleIdentifier: "com.apple.TextEdit"), categories: [.selectedText],
            window: .init(acceptedAt: now(), expiresAt: .distantFuture)
        )]
        // No retention or transmission grants are inferred from local access.
    }
}
