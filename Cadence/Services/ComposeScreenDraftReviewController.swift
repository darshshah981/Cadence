import Foundation
import OSLog

private let composeScreenDraftReviewLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeScreenDraftReview"
)

enum ComposeScreenDraftReviewPhase: Equatable {
    case idle
    case awaitingCaptureApproval
    case choosingAndReading
    case awaitingProviderApproval(sourcePreview: String)
    case drafting
    case ready(String)
    case unavailable
}

/// Owns one explicit, copy-only screen-grounded draft attempt. A UI must call
/// the two approval methods from separate affirmative controls. Neither
/// constructing this service nor beginning an attempt reads screen content.
@MainActor
final class ComposeScreenDraftReviewController {
    private let consent: ComposeScreenContextConsentController
    private let screen: ComposeScreenContextActionController
    private let candidateIsCurrent: @MainActor (ScribeScreenContextReviewCandidate) -> Bool
    private let authorizeProviderDispatch: @MainActor (ScribeScreenContextReviewCandidate) async -> Bool
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let now: @MainActor () -> Date
    private var candidate: ScribeScreenContextReviewCandidate?
    private var snapshot: ComposeScreenContextSnapshot?
    private var compilation: ComposeScreenTextDraftCompilation?
    private var operationRevision = UUID()
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    var onPhaseChange: (@MainActor (ComposeScreenDraftReviewPhase) -> Void)?
    private(set) var phase: ComposeScreenDraftReviewPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }

    init(
        consent: ComposeScreenContextConsentController,
        screen: ComposeScreenContextActionController,
        candidateIsCurrent: @escaping @MainActor (ScribeScreenContextReviewCandidate) -> Bool,
        authorizeProviderDispatch: @escaping @MainActor (ScribeScreenContextReviewCandidate) async -> Bool,
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.consent = consent
        self.screen = screen
        self.candidateIsCurrent = candidateIsCurrent
        self.authorizeProviderDispatch = authorizeProviderDispatch
        self.permissions = permissions
        self.now = now
    }

    func begin(_ newCandidate: ScribeScreenContextReviewCandidate) -> Bool {
        cancel()
        guard candidateIsCurrent(newCandidate),
              newCandidate.providerAction.destination == .legacyLocal,
              newCandidate.providerAction.actionIdentity != nil else { return false }
        do {
            try consent.begin(
                actionID: newCandidate.request.id,
                capture: newCandidate.capture,
                eligibility: .eligible
            )
        } catch { return false }
        candidate = newCandidate
        phase = .awaitingCaptureApproval
        let revision = operationRevision
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(Int(ComposeScreenContextConsentController.grantLifetime))) }
            catch { return }
            guard let self, self.operationRevision == revision else { return }
            self.fail()
        }
        return true
    }

    /// Call only after the person confirms the local screenshot/OCR disclosure.
    func approveLocalReading() {
        guard case .awaitingCaptureApproval = phase,
              let candidate, candidateIsCurrent(candidate) else { fail(); return }
        do {
            try consent.approveLocalOCR(
                actionID: candidate.request.id, capture: candidate.capture
            )
        } catch { fail(); return }
        let revision = operationRevision
        phase = .choosingAndReading
        task = Task { [weak self] in
            guard let self else { return }
            let outcome = await screen.captureForExplicitChoice(
                actionID: candidate.request.id,
                capture: candidate.capture,
                eligibility: .eligible
            )
            guard revision == operationRevision, !Task.isCancelled else { return }
            guard candidateIsCurrent(candidate),
                  case let .captured(snapshot) = outcome,
                  snapshot.target.action.actionID == candidate.request.id,
                  snapshot.target.action.captureID == candidate.capture.id,
                  !snapshot.screenText.isEmpty else { fail(); return }
            self.snapshot = snapshot
            phase = .awaitingProviderApproval(sourcePreview: snapshot.screenText)
        }
    }

    /// Call only after a second confirmation naming the exact local recipient
    /// and displaying the OCR text that will be provided to it.
    func approveProviderUse() {
        guard case .awaitingProviderApproval = phase,
              let candidate, let snapshot,
              candidateIsCurrent(candidate),
              let identity = candidate.providerAction.actionIdentity else { fail(); return }
        let provider = ScribeContextProviderBinding(
            actionIdentity: identity,
            recipientOrigin: candidate.providerAction.destination.recipientOrigin,
            providerDisclosureRevision: candidate.providerAction.destination.disclosureVersion
        )
        do {
            try consent.approveProviderUse(
                actionID: candidate.request.id, capture: candidate.capture,
                provider: provider, destination: .legacyLocal
            )
            // Adding the second approval advances the policy revision. Renew
            // capture authority for the same already-read snapshot; it does
            // not capture pixels again or expand the selected window.
            let currentPolicy = consent.policy(
                actionID: candidate.request.id, capture: candidate.capture
            )
            let captureAuthorization = try ScribeContextPolicy.authorize(
                .init(action: snapshot.target.action, operation: .capture(.screenshot)),
                using: currentPolicy, permissions: permissions(), at: now()
            )
            let authorizedSnapshot = ComposeScreenContextSnapshot(
                id: snapshot.id, target: snapshot.target,
                screenText: snapshot.screenText, lines: snapshot.lines,
                capturedAt: snapshot.capturedAt,
                authorization: captureAuthorization,
                limitations: snapshot.limitations
            )
            let prepared = try ComposeScreenTextDraftCompiler.compile(
                request: candidate.request, snapshot: authorizedSnapshot,
                provider: provider, destination: .legacyLocal,
                policy: currentPolicy,
                permissions: permissions(), now: now()
            )
            self.snapshot = authorizedSnapshot
            compilation = prepared
            let revision = operationRevision
            phase = .drafting
            task = Task { [weak self] in
                guard let self else { return }
                guard await authorizeProviderDispatch(candidate),
                      revision == operationRevision, !Task.isCancelled,
                      candidateIsCurrent(candidate),
                      revalidate(prepared, candidate: candidate, snapshot: authorizedSnapshot) else {
                    fail(); return
                }
                do {
                    let result = try await ScribeCoordinator.generate(
                        .init(id: candidate.request.id, input: prepared.input),
                        provider: candidate.providerAction.provider,
                        timeout: .seconds(30)
                    )
                    guard revision == operationRevision, !Task.isCancelled,
                          candidateIsCurrent(candidate),
                          result.requestID == candidate.request.id,
                          revalidate(prepared, candidate: candidate, snapshot: authorizedSnapshot) else {
                        fail(); return
                    }
                    let text = try ComposeScreenTextDraftCompiler.validateOutput(
                        result.text, request: candidate.request, compilation: prepared
                    )
                    phase = .ready(text)
                } catch {
                    composeScreenDraftReviewLogger.debug("Explicit screen draft unavailable")
                    if revision == operationRevision { fail() }
                }
            }
        } catch { fail() }
    }

    func copyableDraft() -> String? {
        guard case let .ready(text) = phase,
              let candidate, let snapshot, let compilation,
              candidateIsCurrent(candidate),
              revalidate(compilation, candidate: candidate, snapshot: snapshot) else {
            fail()
            return nil
        }
        return text
    }

    func cancel() {
        operationRevision = UUID()
        task?.cancel()
        task = nil
        expiryTask?.cancel()
        expiryTask = nil
        consent.revoke(actionID: candidate?.request.id)
        candidate = nil
        snapshot = nil
        compilation = nil
        phase = .idle
    }

    private func fail() {
        operationRevision = UUID()
        task?.cancel()
        task = nil
        expiryTask?.cancel()
        expiryTask = nil
        consent.revoke(actionID: candidate?.request.id)
        candidate = nil
        snapshot = nil
        compilation = nil
        phase = .unavailable
    }

    private func revalidate(
        _ compilation: ComposeScreenTextDraftCompilation,
        candidate: ScribeScreenContextReviewCandidate,
        snapshot: ComposeScreenContextSnapshot
    ) -> Bool {
        (try? ComposeScreenTextDraftCompiler.revalidate(
            compilation, request: candidate.request, snapshot: snapshot,
            provider: compilation.provider, destination: .legacyLocal,
            policy: consent.policy(actionID: candidate.request.id, capture: candidate.capture),
            permissions: permissions(), now: now()
        )) != nil
    }
}
