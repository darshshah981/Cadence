import Foundation
import Testing
@testable import Cadence

struct ScribeContextPolicyTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private let appID = "test.cadence.context"

    @Test
    func defaultPolicyDeniesEveryCaptureEvenWithAllOSPermissions() {
        for category in ScribeContextCaptureCategory.allCases {
            #expect(throws: ScribeContextPolicyRejection.disabled) {
                try authorize(.capture(category), policy: .init())
            }
        }
    }

    @Test
    func osPermissionsAloneDoNotAuthorizeCapture() {
        var policy = ScribeContextPolicySnapshot()
        policy.isEnabled = true
        for category in ScribeContextCaptureCategory.allCases {
            #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
                try authorize(.capture(category), policy: policy)
            }
        }
    }

    @Test
    func selectedTextDoesNotEnableNearbyTextOrScreenshot() throws {
        let policy = capturePolicy([.selectedText])
        _ = try authorize(.capture(.selectedText), policy: policy)
        for category in [ScribeContextCaptureCategory.surroundingText, .screenshot] {
            #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
                try authorize(.capture(category), policy: policy)
            }
        }
    }

    @Test
    func screenshotAndAccessibilityHaveIndependentOSChecks() throws {
        let policy = capturePolicy([.selectedText, .screenshot])
        _ = try authorize(.capture(.screenshot), policy: policy, permissions: .init(screenRecording: true))
        #expect(throws: ScribeContextPolicyRejection.missingPlatformPermission) {
            try authorize(.capture(.selectedText), policy: policy, permissions: .init(screenRecording: true))
        }
        _ = try authorize(.capture(.selectedText), policy: policy, permissions: .init(accessibility: true))
        #expect(throws: ScribeContextPolicyRejection.missingPlatformPermission) {
            try authorize(.capture(.screenshot), policy: policy, permissions: .init(accessibility: true))
        }
    }

    @Test
    func localCaptureCannotAuthorizeRetentionOrCloudTransmission() {
        let policy = capturePolicy([.selectedText])
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try authorize(.retain(categories: [.selectedText], destination: .sessionMemory, until: now + 30), policy: policy)
        }
        #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
            try authorize(.transmit(categories: [.selectedText], provider: provider()), policy: policy)
        }
    }

    @Test
    func retentionDoesNotAuthorizeTransmissionAndSessionDoesNotAuthorizePersistence() throws {
        var policy = capturePolicy([.selectedText])
        policy.retentionGrants = [retentionGrant(destination: .sessionMemory)]
        _ = try authorize(.retain(categories: [.selectedText], destination: .sessionMemory, until: now + 30), policy: policy)
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try authorize(.retain(categories: [.selectedText], destination: .persistentMemory, until: now + 30), policy: policy)
        }
        #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
            try authorize(.transmit(categories: [.selectedText], provider: provider()), policy: policy)
        }
    }

    @Test
    func retentionRequiresFiniteBoundWithinBothDurationAndGrantExpiry() throws {
        var policy = capturePolicy([.selectedText])
        policy.retentionGrants = [retentionGrant(destination: .persistentMemory)]
        _ = try authorize(.retain(categories: [.selectedText], destination: .persistentMemory, until: now + 60), policy: policy)
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try authorize(.retain(categories: [.selectedText], destination: .persistentMemory, until: now + 61), policy: policy)
        }
        #expect(throws: ScribeContextPolicyRejection.invalidRequest) {
            try authorize(.retain(categories: [.selectedText], destination: .persistentMemory, until: now), policy: policy)
        }
        #expect(throws: ScribeContextPolicyRejection.invalidRequest) {
            try authorize(.retain(categories: [.selectedText], destination: .persistentMemory, until: .distantFuture), policy: policy, action: action(surfaceID: nil))
        }
        policy.retentionGrants = [.init(
            id: UUID(), scope: .application(bundleIdentifier: appID), categories: [.selectedText],
            destination: .persistentMemory, maximumRetentionInterval: 60,
            window: window(expiresAt: now + 30)
        )]
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try authorize(.retain(categories: [.selectedText], destination: .persistentMemory, until: now + 31), policy: policy)
        }
    }

    @Test
    func transmissionAndRetentionGrantsCannotEnableLocalCapture() {
        let recipient = provider()
        var policy = capturePolicy([])
        policy.transmissionGrants = [transmissionGrant(provider: recipient)]
        policy.retentionGrants = [retentionGrant(destination: .sessionMemory)]
        for operation in [
            ScribeContextOperation.capture(.selectedText),
            .transmit(categories: [.selectedText], provider: recipient),
            .retain(categories: [.selectedText], destination: .sessionMemory, until: now + 30)
        ] {
            #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
                try authorize(operation, policy: policy)
            }
        }
    }

    @Test
    func transmissionRequiresEveryCategoryIncludingOCRSeparatelyFromImage() throws {
        let recipient = provider()
        var policy = capturePolicy([.selectedText, .screenshot])
        policy.transmissionGrants = [transmissionGrant(provider: recipient, categories: [.screenText])]
        _ = try authorize(.transmit(categories: [.screenText], provider: recipient), policy: policy)
        for categories: Set<ScribeContextDataCategory> in [[.screenshot], [.screenText, .selectedText]] {
            #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
                try authorize(.transmit(categories: categories, provider: recipient), policy: policy)
            }
        }
    }

    @Test
    func oldAndFutureContextDisclosureReceiptsFailClosed() {
        let recipient = provider()
        for revision in [0, 2] {
            var policy = capturePolicy([.selectedText])
            policy.transmissionGrants = [transmissionGrant(provider: recipient, revision: revision)]
            #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
                try authorize(.transmit(categories: [.selectedText], provider: recipient), policy: policy)
            }
        }
    }

    @Test
    func recipientConfigurationModelConsentAndLibraryChangesDoNotReuseGrant() throws {
        let configurationID = UUID()
        let receiptID = UUID()
        let recipient = provider(configurationID: configurationID, receiptID: receiptID)
        var policy = capturePolicy([.selectedText])
        policy.transmissionGrants = [transmissionGrant(provider: recipient)]
        _ = try authorize(.transmit(categories: [.selectedText], provider: recipient), policy: policy)
        let changed = [
            provider(configurationID: UUID(), receiptID: receiptID),
            provider(configurationID: configurationID, receiptID: UUID()),
            provider(configurationID: configurationID, receiptID: receiptID, model: "other"),
            provider(configurationID: configurationID, receiptID: receiptID, revision: 2),
            provider(configurationID: configurationID, receiptID: receiptID, origin: "https://other.invalid"),
            provider(configurationID: configurationID, receiptID: receiptID, disclosure: 3)
        ]
        for destination in changed {
            #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
                try authorize(.transmit(categories: [.selectedText], provider: destination), policy: policy)
            }
        }
    }

    @Test
    func appAndSurfaceScopesDoNotBleedAcrossIdentities() throws {
        let surfaceGrant = ScribeContextCaptureGrant(id: UUID(), scope: .surface(bundleIdentifier: appID, opaqueSurfaceID: "thread-a"), categories: [.selectedText], window: window())
        var policy = capturePolicy([.selectedText])
        policy.captureGrants = [surfaceGrant]
        _ = try authorize(.capture(.selectedText), policy: policy)
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try authorize(.capture(.selectedText), policy: policy, action: action(surfaceID: "thread-b"))
        }
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try authorize(.capture(.selectedText), policy: policy, action: action(bundleID: "test.other"))
        }
        #expect(throws: ScribeContextPolicyRejection.unknownApplication) {
            try authorize(.capture(.selectedText), policy: policy, action: action(bundleID: nil))
        }
    }

    @Test
    func exclusionsOverrideEvenExplicitGrants() {
        var policy = capturePolicy([.selectedText, .screenshot])
        policy.excludedScopes = [.surface(bundleIdentifier: appID, opaqueSurfaceID: "thread-a")]
        #expect(throws: ScribeContextPolicyRejection.excludedScope) {
            try authorize(.capture(.selectedText), policy: policy)
        }
        policy.excludedScopes = []
        policy.excludedCategories = [.screenText]
        #expect(throws: ScribeContextPolicyRejection.excludedCategory) {
            try authorize(.capture(.screenshot), policy: policy)
        }
    }

    @Test
    func unresolvedSurfaceCannotBypassSpecificExclusionForItsApp() throws {
        var policy = capturePolicy([.selectedText])
        policy.excludedScopes = [.surface(bundleIdentifier: appID, opaqueSurfaceID: "private-thread")]
        for unresolved: String? in [nil, ""] {
            #expect(throws: ScribeContextPolicyRejection.excludedScope) {
                try authorize(.capture(.selectedText), policy: policy, action: action(surfaceID: unresolved))
            }
        }
        _ = try authorize(.capture(.selectedText), policy: policy, action: action(surfaceID: "known-other-thread"))
        policy.excludedScopes = [.surface(bundleIdentifier: "test.unrelated", opaqueSurfaceID: "private-thread")]
        _ = try authorize(.capture(.selectedText), policy: policy, action: action(surfaceID: nil))
    }

    @Test
    func securePrivateAndUnsupportedSurfacesAlwaysDeny() {
        let policy = capturePolicy(Set(ScribeContextCaptureCategory.allCases))
        for eligibility in [ScribeContextSurfaceEligibility.secure, .privateSurface, .unsupported] {
            #expect(throws: ScribeContextPolicyRejection.ineligibleSurface) {
                try authorize(.capture(.selectedText), policy: policy, action: action(eligibility: eligibility))
            }
        }
    }

    @Test
    func grantsCannotBeUsedBeforeAcceptanceOrAtExpiry() {
        var policy = capturePolicy([.selectedText])
        for grantWindow in [window(acceptedAt: now + 1), window(expiresAt: now)] {
            policy.captureGrants = [.init(id: UUID(), scope: .application(bundleIdentifier: appID), categories: [.selectedText], window: grantWindow)]
            #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
                try authorize(.capture(.selectedText), policy: policy)
            }
        }
    }

    @Test
    func revocationExpiryAndPermissionLossInvalidateInFlightCapture() throws {
        let request = ScribeContextPolicyRequest(action: action(), operation: .capture(.selectedText))
        var policy = capturePolicy([.selectedText])
        let authorization = try ScribeContextPolicy.authorize(request, using: policy, permissions: allPermissions, at: now)
        try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: allPermissions, at: now + 1)
        policy.revokedGrantIDs.insert(policy.captureGrants[0].id)
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: allPermissions, at: now + 1)
        }
        policy.revokedGrantIDs = []
        #expect(throws: ScribeContextPolicyRejection.missingCaptureGrant) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: allPermissions, at: now + 120)
        }
        #expect(throws: ScribeContextPolicyRejection.missingPlatformPermission) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: .init(), at: now + 1)
        }
    }

    @Test
    func revalidationRejectsNewActionCaptureTargetSurfaceAndOperation() throws {
        let initialAction = action()
        let request = ScribeContextPolicyRequest(action: initialAction, operation: .capture(.selectedText))
        let policy = capturePolicy([.selectedText, .surroundingText])
        let authorization = try ScribeContextPolicy.authorize(request, using: policy, permissions: allPermissions, at: now)
        let variants = [
            action(captureID: initialAction.captureID),
            action(actionID: initialAction.actionID),
            action(actionID: initialAction.actionID, captureID: initialAction.captureID, pid: 222),
            action(actionID: initialAction.actionID, captureID: initialAction.captureID, surfaceID: "thread-b")
        ]
        for changedAction in variants {
            #expect(throws: ScribeContextPolicyRejection.actionOrOperationChanged) {
                try ScribeContextPolicy.revalidate(authorization, for: .init(action: changedAction, operation: request.operation), using: policy, permissions: allPermissions, at: now)
            }
        }
        #expect(throws: ScribeContextPolicyRejection.actionOrOperationChanged) {
            try ScribeContextPolicy.revalidate(authorization, for: .init(action: initialAction, operation: .capture(.surroundingText)), using: policy, permissions: allPermissions, at: now)
        }
    }

    @Test
    func changedPolicyRevisionInvalidatesAlreadyIssuedAuthorization() throws {
        let request = ScribeContextPolicyRequest(action: action(), operation: .capture(.selectedText))
        var policy = capturePolicy([.selectedText])
        let authorization = try ScribeContextPolicy.authorize(request, using: policy, permissions: allPermissions, at: now)
        policy.revision = UUID()
        #expect(throws: ScribeContextPolicyRejection.policyChanged) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: allPermissions, at: now)
        }
    }

    @Test
    func transmissionGrantRevocationBlocksFinalEgress() throws {
        let recipient = provider()
        let request = ScribeContextPolicyRequest(action: action(), operation: .transmit(categories: [.selectedText], provider: recipient))
        var policy = capturePolicy([.selectedText])
        let grant = transmissionGrant(provider: recipient)
        policy.transmissionGrants = [grant]
        let authorization = try ScribeContextPolicy.authorize(request, using: policy, permissions: allPermissions, at: now)
        policy.revokedGrantIDs.insert(grant.id)
        #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: allPermissions, at: now)
        }
    }

    @Test
    func retentionRevocationBlocksPendingWrite() throws {
        let request = ScribeContextPolicyRequest(
            action: action(),
            operation: .retain(categories: [.selectedText], destination: .sessionMemory, until: now + 30)
        )
        var policy = capturePolicy([.selectedText])
        let grant = retentionGrant(destination: .sessionMemory)
        policy.retentionGrants = [grant]
        let authorization = try ScribeContextPolicy.authorize(request, using: policy, permissions: allPermissions, at: now)
        policy.revokedGrantIDs.insert(grant.id)
        #expect(throws: ScribeContextPolicyRejection.missingRetentionGrant) {
            try ScribeContextPolicy.revalidate(authorization, for: request, using: policy, permissions: allPermissions, at: now)
        }
    }

    @Test
    func emptyPayloadCannotMintAnAuthorization() {
        let policy = capturePolicy([.selectedText])
        #expect(throws: ScribeContextPolicyRejection.invalidRequest) {
            try authorize(.transmit(categories: [], provider: provider()), policy: policy)
        }
        #expect(throws: ScribeContextPolicyRejection.invalidRequest) {
            try authorize(.retain(categories: [], destination: .sessionMemory, until: now + 1), policy: policy)
        }
    }

    private var allPermissions: ScribeContextPlatformPermissions {
        .init(accessibility: true, screenRecording: true)
    }

    private func authorize(
        _ operation: ScribeContextOperation,
        policy: ScribeContextPolicySnapshot,
        permissions: ScribeContextPlatformPermissions? = nil,
        action: ScribeContextActionBinding? = nil
    ) throws -> ScribeContextAccessAuthorization {
        try ScribeContextPolicy.authorize(.init(action: action ?? self.action(), operation: operation), using: policy, permissions: permissions ?? allPermissions, at: now)
    }

    private func action(
        actionID: UUID = UUID(), captureID: UUID = UUID(),
        bundleID: String? = "test.cadence.context", pid: Int32 = 111,
        surfaceID: String? = "thread-a", eligibility: ScribeContextSurfaceEligibility = .eligible
    ) -> ScribeContextActionBinding {
        .init(actionID: actionID, captureID: captureID, target: .init(processIdentifier: pid, bundleIdentifier: bundleID), opaqueSurfaceID: surfaceID, eligibility: eligibility)
    }

    private func window(acceptedAt: Date? = nil, expiresAt: Date? = nil) -> ScribeContextGrantWindow {
        .init(acceptedAt: acceptedAt ?? now - 10, expiresAt: expiresAt ?? now + 120)
    }

    private func capturePolicy(_ categories: Set<ScribeContextCaptureCategory>) -> ScribeContextPolicySnapshot {
        var policy = ScribeContextPolicySnapshot()
        policy.isEnabled = true
        policy.captureGrants = [.init(id: UUID(), scope: .application(bundleIdentifier: appID), categories: categories, window: window())]
        return policy
    }

    private func retentionGrant(destination: ScribeContextRetentionDestination) -> ScribeContextRetentionGrant {
        .init(id: UUID(), scope: .application(bundleIdentifier: appID), categories: [.selectedText], destination: destination, maximumRetentionInterval: 60, window: window())
    }

    private func provider(
        configurationID: UUID = UUID(), receiptID: UUID = UUID(), model: String = "test-model",
        revision: Int = 1, origin: String = "https://test.invalid", disclosure: Int = 2
    ) -> ScribeContextProviderBinding {
        .init(actionIdentity: .init(configurationID: configurationID, libraryRevision: revision, consentReceiptID: receiptID, selectedModelID: model), recipientOrigin: origin, providerDisclosureRevision: disclosure)
    }

    private func transmissionGrant(
        provider: ScribeContextProviderBinding, categories: Set<ScribeContextDataCategory> = [.selectedText],
        revision: Int = ScribeContextTransmissionGrant.currentContextDisclosureRevision
    ) -> ScribeContextTransmissionGrant {
        .init(id: UUID(), scope: .application(bundleIdentifier: appID), provider: provider, categories: categories, contextDisclosureRevision: revision, window: window())
    }
}
