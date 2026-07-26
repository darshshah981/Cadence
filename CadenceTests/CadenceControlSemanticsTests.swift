import Foundation
import Testing
@testable import Cadence

struct CadenceControlSemanticsTests {
    @Test
    func actionDescriptorsHaveStableIdentityAndSafeKeyboardRoles() {
        let result = ScribeResult(requestID: UUID(), text: "Selectable draft")
        let actions = ScribeActionPolicy.actions(
            for: .reviewing(result),
            hasLiteralTranscript: true,
            canRetryGeneration: true,
            targetDisplayName: "Slack"
        )

        #expect(actions.map(\.id.rawValue) == [
            "scribe.discard-draft",
            "scribe.record-again",
            "scribe.retry-polish",
            "scribe.copy-unpolished",
            "scribe.insert-unpolished",
            "scribe.copy-polished",
            "scribe.insert-polished"
        ])
        #expect(actions.last?.title == "Insert polished into Slack")
        #expect(actions.last?.keyboardShortcut == .defaultAction)
        #expect(actions.filter { $0.keyboardShortcut == .defaultAction }.count == 1)
        #expect(!actions.contains {
            $0.role == .destructive && $0.keyboardShortcut != .none
        })
        #expect(ScribeActionPolicy.isValid(actions))
    }

    @Test
    func recoveryKeepsDraftAndNeverOffersDraftAgain() {
        let result = ScribeResult(requestID: UUID(), text: "Selectable draft")
        let actions = ScribeActionPolicy.actions(
            for: .insertionRecovery(result),
            hasLiteralTranscript: true,
            canRetryGeneration: true,
            targetDisplayName: "Claude"
        )

        #expect(actions.map(\.id.rawValue) == [
            "scribe.discard-draft",
            "scribe.copy-unpolished",
            "scribe.insert-unpolished",
            "scribe.copy-polished",
            "scribe.insert-polished"
        ])
        #expect(actions.last?.title == "Return to Claude and insert polished")
        #expect(!actions.contains { $0.id.rawValue == "scribe.record-again" })
        #expect(ScribeActionPolicy.requiresDiscardConfirmation(
            for: .insertionRecovery(result),
            hasRecoverableContent: true
        ))
    }

    @Test
    func environmentCueAppearsExactlyDuringReviewAndRecovery() {
        let requestID = UUID()
        let result = ScribeResult(requestID: requestID, text: "Draft")
        let states: [ScribeSessionState] = [
            .idle,
            .listening(requestID: requestID),
            .transcribing(requestID: requestID),
            .generating(requestID: requestID),
            .generatingSlow(requestID: requestID),
            .reviewing(result),
            .insertionRecovery(result),
            .inserting(requestID: requestID),
            .succeeded(requestID: requestID),
            .failed(requestID: requestID, error: .offline)
        ]

        #expect(states.filter(ScribeActionPolicy.showsEnvironmentCue).count == 2)
        #expect(ScribeActionPolicy.showsEnvironmentCue(.reviewing(result)))
        #expect(ScribeActionPolicy.showsEnvironmentCue(.insertionRecovery(result)))
    }

    @Test
    func semanticControlsPreserveNativeInteractionKinds() {
        #expect(CadenceControlSemantics.quality.interaction == .segmentedSelector)
        #expect(CadenceControlSemantics.meetingCaptureSource.interaction == .segmentedSelector)
        #expect(CadenceControlSemantics.searchDepth.interaction == .segmentedSelector)
        #expect(CadenceControlSemantics.fillerWords.interaction == .segmentedSelector)
        #expect(CadenceControlSemantics.recognitionModel.interaction == .discreteMenu)
        #expect(CadenceControlSemantics.slackBehavior.interaction == .discreteMenu)
        #expect(CadenceControlSemantics.waveformSensitivity.interaction == .continuousSlider)
        #expect(CadenceControlSemantics.waveformSensitivity.isAccessibilityAdjustable)
    }

    @Test
    func disclosureAndResponsiveMetricsAreFrozen() {
        #expect(CadenceDesignMetrics.disclosureHitTarget == 24)
        #expect(CadenceDesignMetrics.disclosureChevronFrame == 24)
        #expect(CadenceDesignMetrics.compactActionBreakpoint == 560)
        #expect(ScribeLaunchFixtures.supportedPanelWidths == [520, 559, 560, 720])
    }

    @Test(arguments: [false, true])
    func disclosureChevronIsCenteredForOneAndTwoLineRows(isExpanded: Bool) {
        for labelHeight in [17.0, 34.0] {
            let geometry = CadenceDisclosureLayoutGeometry(
                labelHeight: labelHeight,
                isExpanded: isExpanded
            )
            #expect(geometry.isExpanded == isExpanded)
            #expect(geometry.chevronMidY == geometry.rowMidY)
            #expect(geometry.chevronFrame.height == CadenceDesignMetrics.disclosureChevronFrame)
        }
    }

    @Test
    func scribeActionAccessibilityIdentifiersFollowSourceOrder() {
        let result = ScribeResult(requestID: UUID(), text: "Draft")
        let actions = ScribeActionPolicy.actions(
            for: .reviewing(result),
            hasLiteralTranscript: true,
            canRetryGeneration: true,
            targetDisplayName: "Slack"
        )

        #expect(actions.map { CadenceActionGroup.actionAccessibilityIdentifier($0.id) } == [
            "scribe-action-discard-draft",
            "scribe-action-record-again",
            "scribe-action-retry-polish",
            "scribe-action-copy-unpolished",
            "scribe-action-insert-unpolished",
            "scribe-action-copy-polished",
            "scribe-action-insert-polished"
        ])
    }

    @Test
    func accessibilityPreferencesHonorDebugOverrides() {
        let system = CadenceAccessibilityPreferences(
            reduceMotion: false,
            reduceTransparency: false,
            differentiateWithoutColor: false,
            increasedContrast: false
        )
        let override = CadenceAccessibilityPreferences(
            reduceMotion: true,
            reduceTransparency: true,
            differentiateWithoutColor: true,
            increasedContrast: true
        )

        #expect(system.resolving(debugOverride: override) == override)
    }

    @Test
    func recoverableContentDrivesDiscardConfirmationIncludingFailures() {
        let requestID = UUID()
        let failed = ScribeSessionState.failed(requestID: requestID, error: .offline)
        #expect(ScribeActionPolicy.hasRecoverableContent(
            in: failed,
            literalTranscript: "retained spoken words"
        ))
        #expect(ScribeActionPolicy.requiresDiscardConfirmation(
            for: failed,
            hasRecoverableContent: true
        ))
        #expect(!ScribeActionPolicy.requiresDiscardConfirmation(
            for: failed,
            hasRecoverableContent: false
        ))

        let actions = ScribeActionPolicy.actions(
            for: failed,
            hasLiteralTranscript: true,
            canRetryGeneration: true
        )
        #expect(actions.first?.title == "Discard draft")
    }

    @Test
    func disabledAndLoadingActionsCannotOwnNativeActivation() {
        let descriptor = CadenceActionDescriptor(
            id: CadenceActionID(rawValue: "test.loading"),
            title: "Working",
            role: .primary,
            keyboardShortcut: .defaultAction,
            isEnabled: true,
            isLoading: true,
            route: .close
        )
        #expect(descriptor.isLoading)
        #expect(!descriptor.canActivate)
        #expect(descriptor.keyboardShortcut == .defaultAction)
        #expect(ScribeActionPolicy.isValid([descriptor]))
    }
}
