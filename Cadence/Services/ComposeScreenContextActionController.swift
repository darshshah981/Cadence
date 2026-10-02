import CoreGraphics
import Foundation
import OSLog

private let composeScreenContextActionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeScreenContextAction"
)

/// Joins an explicit window choice to one live Compose action. The owner must
/// supply a separately granted screenshot policy and a verified target check;
/// all defaults deny. This service never stores pixels, OCR text, or a grant.
@MainActor
final class ComposeScreenContextActionController: @preconcurrency ComposeScreenTargetVerifying {
    private struct Active {
        let actionID: UUID
        let capture: ScribeContextSnapshot
        let action: ScribeContextActionBinding
        let authorization: ScribeContextAccessAuthorization
        var target: ComposeScreenContextTarget?
    }

    private let picker: any ComposeScreenWindowChoosing
    private let captureAdapter: (any ComposeScreenCapturing)?
    private let ocr: any ComposeScreenOCRRecognizing
    private let policy: @MainActor () -> ScribeContextPolicySnapshot
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let actionIsCurrent: @MainActor (UUID) -> Bool
    private let captureIsCurrent: @MainActor (ScribeContextSnapshot) -> Bool
    private let focusedWindowFrame: @MainActor (ScribeContextSnapshot) throws -> CGRect?
    private let targetIsCurrent: @MainActor (ScribeContextSnapshot) async -> Bool
    private let now: @MainActor () -> Date
    private var active: Active?

    private lazy var service = ComposeScreenContextService(
        captureAdapter: captureAdapter ?? SystemComposeScreenCaptureAdapter(
            authority: { [weak self] window in self?.authorizes(window) == true }
        ),
        ocr: ocr,
        verifier: self,
        policy: { [weak self] in self?.policy() ?? .init() },
        permissions: { [weak self] in self?.permissions() ?? .init() },
        currentTarget: { [weak self] in self?.active?.target },
        now: { [weak self] in self?.now() ?? Date() }
    )

    init(
        picker: any ComposeScreenWindowChoosing,
        captureAdapter: (any ComposeScreenCapturing)? = nil,
        ocr: any ComposeScreenOCRRecognizing = VisionComposeScreenOCRAdapter(),
        policy: @escaping @MainActor () -> ScribeContextPolicySnapshot = { .init() },
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions = { .init() },
        actionIsCurrent: @escaping @MainActor (UUID) -> Bool = { _ in false },
        captureIsCurrent: @escaping @MainActor (ScribeContextSnapshot) -> Bool = { _ in false },
        focusedWindowFrame: @escaping @MainActor (ScribeContextSnapshot) throws -> CGRect? = { _ in nil },
        targetIsCurrent: @escaping @MainActor (ScribeContextSnapshot) async -> Bool = { _ in false },
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.picker = picker
        self.captureAdapter = captureAdapter
        self.ocr = ocr
        self.policy = policy
        self.permissions = permissions
        self.actionIsCurrent = actionIsCurrent
        self.captureIsCurrent = captureIsCurrent
        self.focusedWindowFrame = focusedWindowFrame
        self.targetIsCurrent = targetIsCurrent
        self.now = now
    }

    func captureForExplicitChoice(
        actionID: UUID,
        capture: ScribeContextSnapshot,
        eligibility: ScribeContextSurfaceEligibility,
        budget: ComposeScreenCaptureBudget = .init()
    ) async -> ComposeScreenCaptureOutcome {
        guard active == nil else { return .unavailable(.invalidTarget) }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        guard budget.isValid else { return .unavailable(.invalidBudget) }
        guard actionIsCurrent(actionID), captureIsCurrent(capture),
              capture.id == capture.applicationTarget.id,
              capture.applicationTarget.source == .scribeAccessibility,
              capture.target.processIdentifier == capture.applicationTarget.process.processIdentifier,
              capture.target.bundleIdentifier == capture.applicationTarget.process.bundleIdentifier else {
            return .unavailable(.targetChanged)
        }
        let action = ScribeContextActionBinding(
            actionID: actionID, captureID: capture.id, target: capture.target,
            opaqueSurfaceID: nil, eligibility: eligibility
        )
        let request = ScribeContextPolicyRequest(action: action, operation: .capture(.screenshot))
        let authorization: ScribeContextAccessAuthorization
        do {
            authorization = try ScribeContextPolicy.authorize(
                request, using: policy(), permissions: permissions(), at: now()
            )
        } catch let rejection as ScribeContextPolicyRejection {
            return .unavailable(.policy(rejection))
        } catch {
            return .unavailable(.captureFailed)
        }
        active = .init(actionID: actionID, capture: capture, action: action,
                       authorization: authorization, target: nil)
        defer { active = nil }
        do {
            guard let expectedFrame = try focusedWindowFrame(capture),
                  ComposeScreenWindowPickerPolicy.valid(expectedFrame) else {
                throw ComposeScreenCaptureFailure.invalidTarget
            }
            try revalidateCurrentAction()
            let window = try await picker.chooseWindow(
                actionID: actionID, capture: capture, expectedFrame: expectedFrame
            )
            try revalidateCurrentAction()
            guard await targetIsCurrent(capture) else {
                throw ComposeScreenCaptureFailure.targetChanged
            }
            try revalidateCurrentAction()
            // Do not trust a custom or late picker result: apply the same
            // process and geometry conditions required by the native adapter.
            guard window.windowID != 0,
                  window.processIdentifier == capture.target.processIdentifier,
                  window.bundleIdentifier == capture.target.bundleIdentifier,
                  window.processIdentity == capture.applicationTarget.process,
                  let frame = window.expectedFrame,
                  frame == expectedFrame,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else {
                throw ComposeScreenCaptureFailure.invalidTarget
            }
            let target = ComposeScreenContextTarget(action: action, window: window)
            active?.target = target
            let outcome = await service.capture(target: target, budget: budget)
            guard case .captured = outcome else { return outcome }
            try revalidateCurrentAction()
            guard await targetIsCurrent(capture) else {
                throw ComposeScreenCaptureFailure.targetChanged
            }
            try revalidateCurrentAction()
            return outcome
        } catch let failure as ComposeScreenCaptureFailure {
            return .unavailable(failure)
        } catch let rejection as ScribeContextPolicyRejection {
            return .unavailable(.policy(rejection))
        } catch let failure as ComposeScreenWindowPickerError {
            return .unavailable(map(failure))
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            composeScreenContextActionLogger.debug("Explicit screen context unavailable")
            return .unavailable(.captureFailed)
        }
    }

    func verify(_ target: ComposeScreenContextTarget) async -> Bool {
        guard active?.target == target else { return false }
        do { try revalidateCurrentAction() } catch { return false }
        guard let capture = active?.capture, await targetIsCurrent(capture) else { return false }
        do { try revalidateCurrentAction() } catch { return false }
        return active?.target == target
    }

    private func authorizes(_ window: ComposeScreenWindowIdentity) -> Bool {
        guard active?.target?.window == window else { return false }
        do { try revalidateCurrentAction(); return true } catch { return false }
    }

    private func revalidateCurrentAction() throws {
        try Task.checkCancellation()
        guard let active, actionIsCurrent(active.actionID), captureIsCurrent(active.capture) else {
            throw ComposeScreenCaptureFailure.targetChanged
        }
        try ScribeContextPolicy.revalidate(
            active.authorization,
            for: .init(action: active.action, operation: .capture(.screenshot)),
            using: policy(), permissions: permissions(), at: now()
        )
    }

    private func map(_ error: ComposeScreenWindowPickerError) -> ComposeScreenCaptureFailure {
        switch error {
        case .unavailable: return .unsupported
        case .busy, .invalidSelection: return .invalidTarget
        case .targetChanged: return .targetChanged
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
    }
}
