import Testing
@testable import Cadence

@MainActor
struct ScribeProviderSetupModelTests {
    @Test
    func localStatusRespectsDisabledStateAndShowsSpecificRecovery() {
        let preparing = "Apple Intelligence is preparing its model."
        #expect(ScribeProviderReadiness.disabled.statusText(
            configuredKind: .legacyLocal,
            onDeviceUnavailableReason: nil
        ) == "Compose is disabled · no API key needed")
        #expect(ScribeProviderReadiness.disabled.statusText(
            configuredKind: .legacyLocal,
            onDeviceUnavailableReason: preparing
        ) == "Compose is disabled · no API key needed")
        #expect(ScribeProviderReadiness.disabled.statusText(
            configuredKind: .deepSeek,
            onDeviceUnavailableReason: nil
        ) == "Compose is disabled · provider key retained")
        #expect(ScribeProviderReadiness.temporarilyUnavailable(.legacyLocal).statusText(
            configuredKind: .legacyLocal,
            onDeviceUnavailableReason: preparing
        ) == preparing)
        #expect(ScribeProviderReadiness.ready(.legacyLocal).statusText(
            configuredKind: .legacyLocal,
            onDeviceUnavailableReason: nil
        ) == "On-device · no API key · review before insert")
        #expect(ScribeProviderReadiness.ready(.deepSeek).statusText(
            configuredKind: .deepSeek,
            onDeviceUnavailableReason: preparing
        ) == "DeepSeek connected · review before insert")
    }

    @Test
    func providerSetupPlacementCoversEveryReadinessAndConfigurationState() {
        let expectations: [(ScribeProviderReadiness, ScribeProviderSetupPlacement)] = [
            (.setupRequired, .summary),
            (.configurationInvalid, .summary),
            (.needsAttention(.deepSeek), .summary),
            (.removed, .summary),
            (.ready(.deepSeek), .management),
            (.disabled, .management),
            (.validating, .management),
            (.temporarilyUnavailable(.deepSeek), .management),
            (.deprecated(.deepSeek), .management)
        ]
        for (readiness, configuredPlacement) in expectations {
            #expect(ScribeProviderSetupPlacement.resolve(
                hasConfiguredProvider: true, readiness: readiness
            ) == configuredPlacement)
            // Without a configured provider there is no Manage disclosure;
            // setup must remain reachable even during a readiness transition.
            #expect(ScribeProviderSetupPlacement.resolve(
                hasConfiguredProvider: false, readiness: readiness
            ) == .summary)
        }
    }

    @Test
    func providerChoiceStartsEmptyAndDisclosurePrecedesCredential() {
        let model = ScribeProviderSetupModel()

        #expect(model.choice == nil)
        #expect(model.stage == .chooseProvider)

        model.choose(.deepSeek)
        #expect(model.stage == .disclosure)
        model.acceptDisclosure()
        #expect(model.stage == .credential)
    }

    @Test
    func advancedDetailsAreValidatedLocallyAndCancelClearsSecret() {
        let model = ScribeProviderSetupModel()
        model.choose(.advanced)
        model.advancedBaseURL = "http://unsafe.example/v1"
        model.advancedModel = "model"
        model.submitAdvancedConfiguration()
        #expect(model.stage == .advancedConfiguration)
        #expect(model.failureMessage != nil)

        model.advancedBaseURL = "https://safe.example/v1"
        model.submitAdvancedConfiguration()
        #expect(model.stage == .disclosure)
        #expect(model.normalizedAdvancedEndpoint?.requestURL.absoluteString == "https://safe.example/v1/chat/completions")

        model.acceptDisclosure()
        model.credential = "fixture-credential"
        model.clearCandidate()
        #expect(model.credential.isEmpty)
    }

    @Test
    func practiceDraftIsReviewOnlyAndCanReturnToReady() {
        let model = ScribeProviderSetupModel()
        model.choose(.deepSeek)
        model.acceptDisclosure()
        model.credential = "fixture-key"
        #expect(model.beginValidation())
        model.validationSucceeded()

        model.beginPractice()
        #expect(model.stage == .practicing)
        model.practiceSucceeded("Synthetic practice draft")
        #expect(model.stage == .practice)
        #expect(model.practiceDraft == "Synthetic practice draft")
        model.goBack()
        #expect(model.stage == .ready)
        #expect(model.practiceDraft == nil)
    }
}
