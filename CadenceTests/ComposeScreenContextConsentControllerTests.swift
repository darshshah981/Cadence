import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeScreenContextConsentControllerTests {
    @Test
    func localOCRApprovalDoesNotAuthorizeProviderTransmission() throws {
        let fixture = Fixture()
        try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                     eligibility: .eligible)
        #expect(!fixture.controller.approvedForPicker(
            actionID: fixture.actionID, capture: fixture.capture
        ))
        #expect(fixture.controller.policy(actionID: fixture.actionID,
                                          capture: fixture.capture).isEnabled == false)
        try fixture.controller.approveLocalOCR(actionID: fixture.actionID, capture: fixture.capture)
        let policy = fixture.controller.policy(actionID: fixture.actionID, capture: fixture.capture)
        #expect(fixture.controller.approvedForPicker(
            actionID: fixture.actionID, capture: fixture.capture
        ))
        let captureAuthorization = try ScribeContextPolicy.authorize(
            .init(action: fixture.action, operation: .capture(.screenshot)),
            using: policy, permissions: .init(screenRecording: true), at: fixture.now
        )
        #expect(!captureAuthorization.grantIDs.isEmpty)
        #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
            _ = try ScribeContextPolicy.authorize(
                fixture.transmissionRequest, using: policy,
                permissions: .init(screenRecording: true), at: fixture.now
            )
        }
    }

    @Test
    func secondConfirmationGrantsOnlyThePinnedProviderAndAction() throws {
        let fixture = Fixture()
        try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                     eligibility: .eligible)
        #expect(throws: ComposeScreenContextConsentError.captureNotApproved) {
            try fixture.controller.approveProviderUse(
                actionID: fixture.actionID, capture: fixture.capture,
                provider: fixture.provider, destination: .legacyLocal
            )
        }
        try fixture.controller.approveLocalOCR(actionID: fixture.actionID, capture: fixture.capture)
        try fixture.controller.approveProviderUse(
            actionID: fixture.actionID, capture: fixture.capture,
            provider: fixture.provider, destination: .legacyLocal
        )
        let policy = fixture.controller.policy(actionID: fixture.actionID, capture: fixture.capture)
        let transmissionAuthorization = try ScribeContextPolicy.authorize(
            fixture.transmissionRequest, using: policy,
            permissions: .init(screenRecording: true), at: fixture.now
        )
        #expect(transmissionAuthorization.grantIDs.count == 2)
        let wrongProvider = ScribeContextProviderBinding(
            actionIdentity: .init(configurationID: UUID(), libraryRevision: 1,
                                  selectedModelID: "other"),
            recipientOrigin: fixture.provider.recipientOrigin,
            providerDisclosureRevision: fixture.provider.providerDisclosureRevision
        )
        #expect(throws: ScribeContextPolicyRejection.missingTransmissionGrant) {
            _ = try ScribeContextPolicy.authorize(
                .init(action: fixture.action,
                      operation: .transmit(categories: [.screenText], provider: wrongProvider)),
                using: policy, permissions: .init(screenRecording: true), at: fixture.now
            )
        }
        #expect(!fixture.controller.policy(actionID: UUID(), capture: fixture.capture).isEnabled)
    }

    @Test
    func changedProviderRevocationAndExpiryCloseTheGrant() throws {
        let fixture = Fixture()
        try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                     eligibility: .eligible)
        try fixture.controller.approveLocalOCR(actionID: fixture.actionID, capture: fixture.capture)
        try fixture.controller.approveProviderUse(
            actionID: fixture.actionID, capture: fixture.capture,
            provider: fixture.provider, destination: .legacyLocal
        )
        fixture.currentProvider = nil
        #expect(fixture.controller.policy(actionID: fixture.actionID,
                                          capture: fixture.capture).transmissionGrants.isEmpty)
        fixture.currentProvider = fixture.provider
        fixture.controller.revoke(actionID: fixture.actionID)
        #expect(!fixture.controller.policy(actionID: fixture.actionID,
                                           capture: fixture.capture).isEnabled)

        try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                     eligibility: .eligible)
        try fixture.controller.approveLocalOCR(actionID: fixture.actionID, capture: fixture.capture)
        fixture.now.addTimeInterval(ComposeScreenContextConsentController.grantLifetime)
        #expect(!fixture.controller.approvedForPicker(
            actionID: fixture.actionID, capture: fixture.capture
        ))
        #expect(!fixture.controller.policy(actionID: fixture.actionID,
                                           capture: fixture.capture).isEnabled)
    }

    @Test
    func privateOrStaleTargetCannotStartConsent() {
        let fixture = Fixture()
        #expect(throws: ComposeScreenContextConsentError.ineligibleSurface) {
            try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                         eligibility: .privateSurface)
        }
        fixture.currentActionID = nil
        #expect(throws: ComposeScreenContextConsentError.invalidAction) {
            try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                         eligibility: .eligible)
        }
        #expect(!fixture.controller.policy(actionID: fixture.actionID,
                                           capture: fixture.capture).isEnabled)
    }

    @Test
    func recipientMismatchCannotCreateTransmissionGrant() throws {
        let fixture = Fixture()
        try fixture.controller.begin(actionID: fixture.actionID, capture: fixture.capture,
                                     eligibility: .eligible)
        try fixture.controller.approveLocalOCR(actionID: fixture.actionID, capture: fixture.capture)
        #expect(throws: ComposeScreenContextConsentError.providerMismatch) {
            try fixture.controller.approveProviderUse(
                actionID: fixture.actionID, capture: fixture.capture,
                provider: fixture.provider, destination: .openAIDirect
            )
        }
        #expect(fixture.controller.policy(actionID: fixture.actionID,
                                          capture: fixture.capture).transmissionGrants.isEmpty)
    }

    @MainActor
    private final class Fixture {
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let actionID = UUID()
        let capture: ScribeContextSnapshot
        let provider: ScribeContextProviderBinding
        var currentActionID: UUID?
        var currentCapture: ScribeContextSnapshot?
        var currentProvider: ScribeContextProviderBinding?
        var action: ScribeContextActionBinding {
            .init(actionID: actionID, captureID: capture.id, target: capture.target,
                  opaqueSurfaceID: nil, eligibility: .eligible)
        }
        var transmissionRequest: ScribeContextPolicyRequest {
            .init(action: action, operation: .transmit(categories: [.screenText], provider: provider))
        }
        lazy var controller = ComposeScreenContextConsentController(
            actionIsCurrent: { [unowned self] in self.currentActionID == $0 },
            captureIsCurrent: { [unowned self] in self.currentCapture == $0 },
            providerIsCurrent: { [unowned self] in self.currentProvider == $0 },
            now: { [unowned self] in self.now }
        )

        init() {
            let id = UUID()
            let process = ApplicationProcessIdentity(
                processIdentifier: 42, bundleIdentifier: "test.editor",
                bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
                incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 100)
            )
            capture = .init(id: id,
                            target: .init(processIdentifier: 42, bundleIdentifier: "test.editor"),
                            selectedText: "", applicationTarget: .init(
                                id: id, process: process, identityRevision: 1,
                                captureRevision: 1, source: .scribeAccessibility
                            ))
            provider = .init(
                actionIdentity: .init(configurationID: UUID(), libraryRevision: 1,
                                      selectedModelID: "local"),
                recipientOrigin: ScribeEgressDestination.legacyLocal.recipientOrigin,
                providerDisclosureRevision: ScribeEgressDestination.legacyLocal.disclosureVersion
            )
            currentActionID = actionID
            currentCapture = capture
            currentProvider = provider
        }
    }
}
