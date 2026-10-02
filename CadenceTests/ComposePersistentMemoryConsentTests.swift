import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposePersistentMemoryConsentTests {
    @Test
    func defaultAndIncompleteConsentIssueNoDurableGrants() {
        var rolloutEnabled = true
        let controller = ComposePersistentMemoryConsentController(enabled: { rolloutEnabled })
        #expect(!controller.policy.isEnabled)
        #expect(controller.policy.captureGrants.isEmpty)
        #expect(controller.policy.retentionGrants.isEmpty)

        controller.updatePreferences(.init(isEnabled: true, textEditAllowed: true))
        #expect(!controller.policy.isEnabled)
        controller.updatePreferences(.init(
            isEnabled: true, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision + 1
        ))
        #expect(!controller.policy.isEnabled)

        rolloutEnabled = false
        controller.refreshRollout()
        #expect(!controller.policy.isEnabled)
    }

    @Test
    func currentDisclosureGrantsOnlyLocalTextEditCaptureAndThirtyDayRetention() throws {
        let controller = ComposePersistentMemoryConsentController(
            preferences: .init(
                isEnabled: true, textEditAllowed: true,
                acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
            ), enabled: { true }
        )
        let policy = controller.policy
        #expect(policy.isEnabled)
        #expect(policy.captureGrants.count == 1)
        #expect(policy.captureGrants[0].scope == .application(bundleIdentifier: "com.apple.TextEdit"))
        #expect(policy.captureGrants[0].categories == [.sessionMemory, .persistentMemory])
        #expect(policy.retentionGrants.count == 1)
        #expect(policy.retentionGrants[0].categories == [.sessionMemory, .persistentMemory])
        #expect(policy.retentionGrants[0].destination == .persistentMemory)
        #expect(policy.retentionGrants[0].maximumRetentionInterval == 30 * 24 * 60 * 60)
        #expect(policy.transmissionGrants.isEmpty)

        controller.updatePreferences(.init(
            isEnabled: false, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
        ))
        #expect(!controller.policy.isEnabled)
        #expect(controller.policy.revision != policy.revision)
        #expect(controller.policy.retentionGrants.isEmpty)
    }

    @Test
    func savedFactDraftUseRequiresSeparateOptInAndRotatesItsRevision() {
        let accepted = ComposePersistentMemoryPreferences(
            isEnabled: true, textEditAllowed: true,
            acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
        )
        let controller = ComposePersistentMemoryConsentController(
            preferences: accepted, enabled: { true }
        )
        #expect(!controller.preferences.permitsLocalDraftUse)
        #expect(controller.policy.transmissionGrants.isEmpty)
        let oldRevision = controller.localUseRevision
        var enabled = accepted
        enabled.useFactsInLocalDrafts = true
        controller.updatePreferences(enabled)
        #expect(controller.preferences.permitsLocalDraftUse)
        #expect(controller.localUseRevision != oldRevision)
        #expect(controller.policy.transmissionGrants.isEmpty)
        let enabledRevision = controller.localUseRevision
        controller.updatePreferences(accepted)
        #expect(!controller.preferences.permitsLocalDraftUse)
        #expect(controller.localUseRevision != enabledRevision)
    }

    @Test
    func actualPolicyRejectsOtherAppsAndLongerRetentionAndRevokesOldAuthorization() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let controller = ComposePersistentMemoryConsentController(
            preferences: .init(
                isEnabled: true, textEditAllowed: true,
                acceptedDisclosureRevision: ComposePersistentMemoryPreferences.currentDisclosureRevision
            ), enabled: { true }, now: { now }
        )
        let action = ScribeContextActionBinding(
            actionID: UUID(), captureID: UUID(),
            target: .init(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            opaqueSurfaceID: "verified-document", eligibility: .eligible
        )
        let request = ScribeContextPolicyRequest(
            action: action,
            operation: .retain(
                categories: [.sessionMemory, .persistentMemory],
                destination: .persistentMemory,
                until: now.addingTimeInterval(ComposePersistentMemoryPreferences.retentionInterval)
            )
        )
        let permissions = ScribeContextPlatformPermissions(accessibility: true)
        let granted = try ScribeContextPolicy.authorize(
            request, using: controller.policy, permissions: permissions, at: now
        )
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try ScribeContextPolicy.authorize(
                .init(action: action, operation: .retain(
                    categories: [.sessionMemory, .persistentMemory],
                    destination: .persistentMemory,
                    until: now.addingTimeInterval(ComposePersistentMemoryPreferences.retentionInterval + 1)
                )), using: controller.policy, permissions: permissions, at: now
            )
        }
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try ScribeContextPolicy.authorize(
                .init(action: .init(
                    actionID: action.actionID, captureID: action.captureID,
                    target: .init(processIdentifier: 43, bundleIdentifier: "com.example.Other"),
                    opaqueSurfaceID: "other", eligibility: .eligible
                ), operation: request.operation),
                using: controller.policy, permissions: permissions, at: now
            )
        }
        controller.updatePreferences(.init())
        #expect(throws: ScribeContextPolicyRejection.policyChanged) {
            try ScribeContextPolicy.revalidate(
                granted, for: request, using: controller.policy,
                permissions: permissions, at: now
            )
        }
    }
}
