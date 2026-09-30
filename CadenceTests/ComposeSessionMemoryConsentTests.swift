import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeSessionMemoryConsentTests {
    @Test
    func captureAndRetentionAreSeparateAndRevocable() throws {
        var rollout = true
        let now = Date(timeIntervalSince1970: 50_000)
        let controller = ComposeSessionMemoryConsentController(
            enabled: { rollout }, now: { now }
        )
        let action = ScribeContextActionBinding(
            actionID: UUID(), captureID: UUID(),
            target: .init(processIdentifier: 77, bundleIdentifier: "com.apple.TextEdit"),
            opaqueSurfaceID: String(repeating: "a", count: 64), eligibility: .eligible
        )
        let permissions = ScribeContextPlatformPermissions(accessibility: true)
        let capture = ScribeContextPolicyRequest(action: action, operation: .capture(.sessionMemory))
        let retain = ScribeContextPolicyRequest(
            action: action, operation: .retain(
                categories: [.sessionMemory], destination: .sessionMemory, until: now + 600
            )
        )
        #expect(throws: ScribeContextPolicyRejection.disabled) {
            try ScribeContextPolicy.authorize(capture, using: controller.policy, permissions: permissions, at: now)
        }

        controller.updatePreferences(.init(isEnabled: true, textEditAllowed: true))
        let read = try ScribeContextPolicy.authorize(capture, using: controller.policy, permissions: permissions, at: now)
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try ScribeContextPolicy.authorize(retain, using: controller.policy, permissions: permissions, at: now)
        }
        #expect(controller.policy.transmissionGrants.isEmpty)

        controller.updatePreferences(.init(isEnabled: true, textEditAllowed: true, rememberExplicitFacts: true))
        _ = try ScribeContextPolicy.authorize(retain, using: controller.policy, permissions: permissions, at: now)
        #expect(throws: ScribeContextPolicyRejection.policyChanged) {
            try ScribeContextPolicy.revalidate(read, for: capture, using: controller.policy,
                                               permissions: permissions, at: now)
        }
        let tooLong = ScribeContextPolicyRequest(
            action: action, operation: .retain(
                categories: [.sessionMemory], destination: .sessionMemory,
                until: now + ScribeSessionMemoryLimits.inactivityInterval + 1
            )
        )
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try ScribeContextPolicy.authorize(tooLong, using: controller.policy,
                                              permissions: permissions, at: now)
        }

        rollout = false
        controller.refreshRollout()
        #expect(throws: ScribeContextPolicyRejection.disabled) {
            try ScribeContextPolicy.authorize(capture, using: controller.policy, permissions: permissions, at: now)
        }
        #expect(controller.preferences.permitsTextEditRetention)
    }

    @Test
    func oldDisclosureAndOtherAppsCannotBorrowConsent() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let old = ComposeSessionMemoryConsentController(
            preferences: .init(isEnabled: true, textEditAllowed: true,
                               rememberExplicitFacts: true, disclosureRevision: 0),
            enabled: { true }, now: { now }
        )
        #expect(!old.policy.isEnabled)
        let current = ComposeSessionMemoryConsentController(
            preferences: .init(isEnabled: true, textEditAllowed: true),
            enabled: { true }, now: { now }
        )
        let other = ScribeContextPolicyRequest(
            action: .init(actionID: UUID(), captureID: UUID(),
                          target: .init(processIdentifier: 88, bundleIdentifier: "com.example.Other"),
                          opaqueSurfaceID: nil, eligibility: .eligible),
            operation: .capture(.sessionMemory)
        )
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try ScribeContextPolicy.authorize(other, using: current.policy,
                                              permissions: .init(accessibility: true), at: now)
        }
    }

    @Test
    func chosenDraftRetentionNeedsItsOwnOptInAndCanBeRevoked() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let controller = ComposeSessionMemoryConsentController(
            preferences: .init(isEnabled: true, textEditAllowed: true),
            enabled: { true }, now: { now }
        )
        let action = ScribeContextActionBinding(
            actionID: UUID(), captureID: UUID(),
            target: .init(processIdentifier: 77, bundleIdentifier: "com.apple.TextEdit"),
            opaqueSurfaceID: String(repeating: "a", count: 64), eligibility: .eligible
        )
        let request = ScribeContextPolicyRequest(
            action: action, operation: .retain(
                categories: [.sessionMemory, .priorDraft], destination: .sessionMemory,
                until: now + 600
            )
        )
        let permissions = ScribeContextPlatformPermissions(accessibility: true)
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try ScribeContextPolicy.authorize(request, using: controller.policy,
                                              permissions: permissions, at: now)
        }
        controller.updatePreferences(.init(
            isEnabled: true, textEditAllowed: true, rememberChosenDrafts: true
        ))
        let authorization = try ScribeContextPolicy.authorize(
            request, using: controller.policy, permissions: permissions, at: now
        )
        #expect(controller.policy.transmissionGrants.isEmpty)
        controller.updatePreferences(.init(isEnabled: true, textEditAllowed: true))
        #expect(throws: ScribeContextPolicyRejection.policyChanged) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: controller.policy,
                                               permissions: permissions, at: now)
        }
    }
}
