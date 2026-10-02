import Foundation
import OSLog

private let scribeConversationActionScopeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribeConversationActionScope"
)

/// Binds one verified conversation identity to the original Compose target.
/// This service retains no content and grants no memory read or write by itself.
/// The memory store separately requires retention authorization for every use.
@MainActor
final class ScribeConversationActionScope {
    private struct ActiveAction {
        let capture: ScribeContextSnapshot
        let access: ScribeSessionMemoryAccess
        let authorization: ScribeContextAccessAuthorization
    }

    private let adapter: any ScribeConversationBindingCapturing
    let identityResolver: ScribeConversationIdentityResolver
    private let enabled: @MainActor () -> Bool
    private let policy: @MainActor () -> ScribeContextPolicySnapshot
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let actionIsCurrent: @MainActor (UUID) -> Bool
    private let targetIsCurrent: @MainActor (ScribeContextSnapshot) -> Bool
    private let now: @MainActor () -> Date
    private var active: ActiveAction?
    private var isRevoked = false

    init(
        adapter: any ScribeConversationBindingCapturing,
        enabled: @escaping @MainActor () -> Bool = { false },
        policy: @escaping @MainActor () -> ScribeContextPolicySnapshot = { .init() },
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions = { .init() },
        actionIsCurrent: @escaping @MainActor (UUID) -> Bool = { _ in false },
        targetIsCurrent: @escaping @MainActor (ScribeContextSnapshot) -> Bool = { _ in false },
        now: @escaping @MainActor () -> Date = Date.init
    ) throws {
        self.adapter = adapter
        self.identityResolver = try ScribeConversationIdentityResolver(adapters: [adapter])
        self.enabled = enabled
        self.policy = policy
        self.permissions = permissions
        self.actionIsCurrent = actionIsCurrent
        self.targetIsCurrent = targetIsCurrent
        self.now = now
    }

    /// Call while the app that owned the recording target is still current.
    /// Unknown apps, unavailable identity, and absent consent simply omit
    /// conversation memory from this action; they never fall back to app scope.
    func begin(actionID: UUID, capture: ScribeContextSnapshot) -> ScribeSessionMemoryAccess? {
        guard !isRevoked, enabled(), policy().isEnabled,
              permissions().accessibility, actionIsCurrent(actionID), targetIsCurrent(capture),
              capture.applicationTarget.id == capture.id else { return nil }
        active = nil
        let process = capture.applicationTarget.process
        guard process.processIdentifier == capture.target.processIdentifier,
              (capture.target.bundleIdentifier == nil
                || capture.target.bundleIdentifier == process.bundleIdentifier),
              process.bundleIdentifier == adapter.registration.hostBundleIdentifier,
              let binding = adapter.captureBinding(actionID: actionID, process: process),
              binding.actionID == actionID, binding.process == process,
              case let .verified(identity) = identityResolver.resolve(
                adapterID: adapter.registration.adapterID, for: binding
              ) else { return nil }

        let action = ScribeContextActionBinding(
            actionID: actionID, captureID: capture.id,
            target: .init(processIdentifier: process.processIdentifier,
                          bundleIdentifier: process.bundleIdentifier),
            opaqueSurfaceID: identity.memoryKey.opaqueValue, eligibility: .eligible
        )
        let request = ScribeContextPolicyRequest(action: action, operation: .capture(.sessionMemory))
        guard let authorization = try? ScribeContextPolicy.authorize(
            request, using: policy(), permissions: permissions(), at: now()
        ) else { return nil }
        let access = ScribeSessionMemoryAccess(
            conversation: identity, currentBinding: binding, contextAction: action
        )
        active = .init(capture: capture, access: access, authorization: authorization)
        scribeConversationActionScopeLogger.debug("Action-scoped conversation identity verified")
        return access
    }

    /// Revalidate after async work, before any memory read/write or provider
    /// compilation. A changed file, target, policy, or OS permission clears the
    /// action rather than exposing a stale memory key.
    func currentAccess(actionID: UUID, capture: ScribeContextSnapshot) -> ScribeSessionMemoryAccess? {
        guard let active else { return nil }
        // A stale callback from another action cannot revoke this one.
        guard active.capture == capture,
              active.access.contextAction.actionID == actionID else { return nil }
        guard !isRevoked, enabled(), permissions().accessibility,
              actionIsCurrent(actionID),
              targetIsCurrent(capture),
              identityResolver.revalidate(active.access.conversation, for: active.access.currentBinding),
              (try? ScribeContextPolicy.revalidate(
                active.authorization, for: active.authorization.request,
                using: policy(), permissions: permissions(), at: now()
              )) != nil else {
            self.active = nil
            return nil
        }
        return active.access
    }

    /// Move a reviewed draft to a new action without asking the adapter to
    /// capture whichever editor is focused now. Cadence's review control may
    /// own focus, so only the already pinned window can supply new evidence.
    func rebind(
        from oldActionID: UUID, to newActionID: UUID,
        capture: ScribeContextSnapshot
    ) -> ScribeSessionMemoryAccess? {
        guard oldActionID != newActionID, let previous = active,
              previous.capture == capture,
              previous.access.contextAction.actionID == oldActionID,
              !isRevoked, enabled(), policy().isEnabled,
              permissions().accessibility, actionIsCurrent(newActionID),
              targetIsCurrent(capture),
              identityResolver.revalidate(
                previous.access.conversation, for: previous.access.currentBinding
              ),
              (try? ScribeContextPolicy.revalidate(
                previous.authorization, for: previous.authorization.request,
                using: policy(), permissions: permissions(), at: now()
              )) != nil else {
            active = nil
            return nil
        }
        let oldBinding = previous.access.currentBinding
        let binding = ScribeConversationActionBinding(
            actionID: newActionID, process: oldBinding.process,
            windowIncarnation: oldBinding.windowIncarnation,
            tabIncarnation: oldBinding.tabIncarnation,
            navigationRevision: oldBinding.navigationRevision
        )
        guard case let .verified(identity) = identityResolver.resolve(
            adapterID: previous.access.conversation.adapterID, for: binding
        ), identity.memoryKey == previous.access.conversation.memoryKey else {
            active = nil
            return nil
        }
        let oldAction = previous.access.contextAction
        let action = ScribeContextActionBinding(
            actionID: newActionID, captureID: oldAction.captureID,
            target: oldAction.target, opaqueSurfaceID: identity.memoryKey.opaqueValue,
            eligibility: .eligible
        )
        let request = ScribeContextPolicyRequest(
            action: action, operation: .capture(.sessionMemory)
        )
        guard let authorization = try? ScribeContextPolicy.authorize(
            request, using: policy(), permissions: permissions(), at: now()
        ) else {
            active = nil
            return nil
        }
        let access = ScribeSessionMemoryAccess(
            conversation: identity, currentBinding: binding, contextAction: action
        )
        active = .init(capture: capture, access: access, authorization: authorization)
        return access
    }

    /// Supply this as the session store's required action authority. An old
    /// access value cannot outlive clear, replacement, or live revalidation.
    func isCurrent(_ access: ScribeSessionMemoryAccess) -> Bool {
        guard let active, active.access == access else { return false }
        return currentAccess(actionID: access.contextAction.actionID, capture: active.capture) == access
    }

    func clear(actionID: UUID? = nil) {
        if let actionID, active?.access.contextAction.actionID != actionID { return }
        active = nil
    }

    func revoke() {
        isRevoked = true
        active = nil
    }
}
