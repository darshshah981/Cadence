import AppKit
import Foundation
import Testing
@testable import Cadence

struct ScribeNotchPresentationTests {
    private let requestID = UUID()

    @Test
    func listeningKeepsTheNotchHiddenAndUsesTheScribePill() {
        let projection = ScribeNotchPresentation.project(
            state: .listening(requestID: requestID),
            literalTranscript: nil,
            failureMessage: nil
        )

        #expect(projection.content == .hidden)
        #expect(projection.pill == .listening)
    }

    @Test
    func transcribingOpensAnEmptyNotchBeforeTextIsAvailable() {
        let projection = ScribeNotchPresentation.project(
            state: .transcribing(requestID: requestID),
            literalTranscript: nil,
            failureMessage: nil
        )

        #expect(projection.content == .transcribing)
        #expect(projection.pill == .transcribing)
        #expect(!projection.allowsReviewActions)
    }

    @Test
    func generationTypesOnlyTheProcessedLocalTranscript() {
        let projection = ScribeNotchPresentation.project(
            state: .generating(requestID: requestID),
            literalTranscript: "Send the revised deck today.",
            failureMessage: nil
        )

        #expect(projection.content == .typingTranscript("Send the revised deck today.", isSlow: false))
        #expect(projection.pill == .transcribing)
        #expect(!projection.allowsReviewActions)
    }

    @Test
    func polishedResultReplacesTheTranscriptBeforeActionsBecomeAvailable() {
        let result = ScribeResult(
            requestID: requestID,
            text: "I finished the revised deck. We can send it today."
        )
        let projection = ScribeNotchPresentation.project(
            state: .reviewing(result),
            literalTranscript: "finished the revised deck we can send it today",
            failureMessage: nil
        )

        #expect(projection.content == .replacing(
            source: "finished the revised deck we can send it today",
            result: result
        ))
        #expect(projection.pill == .transcribing)
        #expect(!projection.allowsReviewActions)
    }

    @Test
    func terminalStatesCloseTheNotchInsteadOfRetainingContent() {
        for state in [
            ScribeSessionState.succeeded(requestID: requestID),
            .cancelled(requestID: requestID),
            .idle
        ] {
            let projection = ScribeNotchPresentation.project(
                state: state,
                literalTranscript: "must not remain visible",
                failureMessage: nil
            )

            #expect(projection.content == .hidden)
        }
    }

    @Test
    func insertionFailureKeepsThePolishedDraftAndExplainsRecovery() {
        let result = ScribeResult(requestID: requestID, text: "Keep this polished draft.")
        let projection = ScribeNotchPresentation.project(
            state: .insertionRecovery(result),
            literalTranscript: "keep polished draft",
            failureMessage: "Return to the original insertion point."
        )

        #expect(projection.content == .insertionRecovery(
            message: "Return to the original insertion point.",
            result: result
        ))
        #expect(projection.pill == .failed)
        #expect(projection.allowsReviewActions)
    }

    @Test
    func insertingImmediatelyHandsFocusBackToTheCapturedEditor() {
        let projection = ScribeNotchPresentation.project(
            state: .inserting(requestID: requestID),
            literalTranscript: "original words",
            failureMessage: nil
        )

        #expect(projection.requiresImmediateFocusHandoff)
        #expect(!projection.allowsReviewActions)
    }

    @Test
    func failureProjectsWhetherRetryMeansRetryOrRecordAgain() {
        let projection = ScribeNotchPresentation.project(
            state: .failed(requestID: requestID, error: .offline),
            literalTranscript: "retained words",
            failureMessage: "Provider offline.",
            canRetryGeneration: true
        )

        #expect(projection.content == .failure(
            message: "Provider offline.",
            literalTranscript: "retained words",
            recovery: .retryGeneration
        ))
        #expect(projection.allowsReviewActions)
    }

    @Test
    func missingProviderProjectsAContextualSetupAction() {
        let failure = ScribeProviderFailure(
            phase: .generation,
            category: .setupRequired,
            retryDisposition: .none
        )
        let projection = ScribeNotchPresentation.project(
            state: .failed(requestID: requestID, error: .unavailable),
            literalTranscript: nil,
            failureMessage: "Scribe needs an AI provider.",
            failureRecovery: .providerRecovery(for: failure)
        )

        #expect(projection.content == .failure(
            message: "Scribe needs an AI provider.",
            literalTranscript: nil,
            recovery: .setUpProvider
        ))
        #expect(projection.allowsReviewActions)
    }

    @Test
    func providerRecoveryOffersSetupForSavedProviderConfigurationErrors() {
        for category in [
            ScribeProviderFailureCategory.configurationInvalid,
            .credentialRejected
        ] {
            let failure = ScribeProviderFailure(
                phase: .generation,
                category: category,
                retryDisposition: .reconnect
            )

            #expect(
                ScribeNotchFailureRecovery.providerRecovery(for: failure)
                    == .reviewProvider
            )
        }
    }

    @Test
    func providerRecoveryDoesNotReplaceRetryForTransientFailures() {
        let offline = ScribeProviderFailure(
            phase: .generation,
            category: .transportUnavailable,
            retryDisposition: .manualNow
        )

        #expect(ScribeNotchFailureRecovery.providerRecovery(for: nil) == nil)
        #expect(
            ScribeNotchFailureRecovery.providerRecovery(for: offline)
                == .retryGeneration
        )
    }

    @Test
    func contextRecoveryPointsToTheRequiredDestination() {
        #expect(
            ScribeNotchFailureRecovery.contextRecovery(for: .noFocusedTarget)
                == .returnToTargetApp
        )
        #expect(
            ScribeNotchFailureRecovery.contextRecovery(for: .accessibilityDenied)
                == .openPermissions
        )
        #expect(
            ScribeNotchFailureRecovery.contextRecovery(for: .secureField) == nil
        )
    }

    @Test
    func onlyTerminalAttentionAutoDismisses() {
        let failure = ScribeNotchPresentation(
            content: .failure(
                message: "Provider offline.",
                literalTranscript: nil,
                recovery: .none
            ),
            pill: .failed
        )
        let reviewed = ScribeNotchPresentation(
            content: .ready(
                ScribeResult(requestID: requestID, text: "Keep this draft.")
            ),
            pill: .scribed
        )
        let recovery = ScribeNotchPresentation(
            content: .insertionRecovery(
                message: "Insertion failed.",
                result: ScribeResult(
                    requestID: requestID,
                    text: "Keep this recoverable draft."
                )
            ),
            pill: .failed
        )

        #expect(ScribeNotchAutoDismissPolicy.delay(for: failure) == .seconds(6))
        #expect(ScribeNotchAutoDismissPolicy.delay(for: reviewed) == nil)
        #expect(ScribeNotchAutoDismissPolicy.delay(for: recovery) == nil)
    }
}

struct ScribeNotchGeometryTests {
    @Test
    func hardwareSurfaceUsesOutwardScreenAttachmentShoulders() {
        #expect(ScribeNotchGeometry.hardwareAttachmentShoulderRadius == 13)
        #expect(
            ScribeNotchGeometry.surfaceBottomCornerRadius
                - ScribeNotchGeometry.hardwareAttachmentShoulderRadius
                == 4
        )
        #expect(
            ScribeNotchMotion.canvasSize.width
                == ScribeNotchGeometry.surfaceSize.width + 26
        )
    }

    private let screen = NSRect(x: 0, y: 0, width: 1_512, height: 982)

    @Test
    func hardwareNotchSurfaceIsTopCenteredAndTouchesTheScreenTop() {
        let frame = ScribeNotchGeometry.expandedFrame(
            screenFrame: screen,
            surfaceSize: NSSize(width: 330, height: 176),
            hasHardwareNotch: true
        )

        #expect(frame == NSRect(x: 591, y: 806, width: 330, height: 176))
    }

    @Test
    func nonNotchedDisplayUsesAVisibleFloatingGap() {
        let frame = ScribeNotchGeometry.expandedFrame(
            screenFrame: screen,
            surfaceSize: NSSize(width: 330, height: 176),
            hasHardwareNotch: false
        )

        #expect(frame == NSRect(x: 591, y: 798, width: 330, height: 176))
    }

    @Test
    func oversizedSurfaceIsClampedInsideTheDisplay() {
        let frame = ScribeNotchGeometry.expandedFrame(
            screenFrame: NSRect(x: 100, y: 20, width: 300, height: 220),
            surfaceSize: NSSize(width: 420, height: 260),
            hasHardwareNotch: true
        )

        #expect(frame == NSRect(x: 100, y: 20, width: 300, height: 220))
    }

    @Test
    func reviewSurfaceUsesTrueBlackPixels() {
        #expect(ScribeNotchPalette.surfaceHex == 0x000000)
    }

    @Test
    func hardwareNotchReservesSpaceBeforeTheStatusRow() {
        #expect(ScribeNotchGeometry.hardwareNotchContentInset == 34)
    }

}

struct ScribeNotchTypingCadenceTests {
    @Test
    func shortAndLongDraftsUseAResponsiveBoundedCadence() {
        #expect(
            ScribeNotchMotion.typingDuration(
                characterCount: 12,
                maximumDuration: ScribeNotchMotion.sourceTypingMaximumDuration
            ) == 0.16
        )
        #expect(
            ScribeNotchMotion.typingDuration(
                characterCount: 500,
                maximumDuration: ScribeNotchMotion.sourceTypingMaximumDuration
            ) == 0.68
        )
        #expect(
            ScribeNotchMotion.typingDuration(
                characterCount: 500,
                maximumDuration: ScribeNotchMotion.resultTypingMaximumDuration
            ) == 0.78
        )
        #expect(ScribeNotchMotion.maximumTypingUpdates == 40)
    }
}

struct ScribeCopyOutsideDismissalPolicyTests {
    private let panelFrame = NSRect(x: 500, y: 700, width: 356, height: 220)

    @Test
    func clickInsideTheVisibleNotchKeepsReviewAvailable() {
        #expect(!ScribeCopyOutsideDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 678, y: 810),
            panelFrame: panelFrame
        ))
    }

    @Test
    func clickOutsideTheVisibleNotchDismissesCopiedReview() {
        #expect(ScribeCopyOutsideDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 100, y: 100),
            panelFrame: panelFrame
        ))
    }

    @Test
    func missingPanelDismissesStaleCopiedReview() {
        #expect(ScribeCopyOutsideDismissalPolicy.shouldDismiss(
            clickLocation: NSPoint(x: 678, y: 810),
            panelFrame: nil
        ))
    }
}

struct ScribeReviewKeyboardPolicyTests {
    @Test
    func successfulReviewSupportsReturnCopyAndEscape() {
        let result = ScribeResult(requestID: UUID(), text: "Ready")

        #expect(
            ScribeReviewKeyboardPolicy.commands(for: .ready(result))
                == [.insert, .copy, .discard]
        )
        #expect(
            ScribeReviewKeyboardPolicy.commands(
                for: .replacing(source: "Original", result: result)
            ) == [.insert, .copy, .discard]
        )
    }

    @Test
    func failureOnlyOffersCommandsBackedByVisibleActions() {
        #expect(
            ScribeReviewKeyboardPolicy.commands(
                for: .failure(
                    message: "Offline",
                    literalTranscript: "Keep this",
                    recovery: .retryGeneration
                )
            ) == [.copy, .discard]
        )
        #expect(
            ScribeReviewKeyboardPolicy.commands(
                for: .failure(
                    message: "Offline",
                    literalTranscript: nil,
                    recovery: .retryGeneration
                )
            ) == [.discard]
        )
    }
}

@MainActor
private final class FakeScribeOutsideClickMonitor: ScribeOutsideClickMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: ((NSPoint) -> Void)?

    func start(handler: @escaping (NSPoint) -> Void) {
        startCount += 1
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        handler = nil
    }

    func emit(_ point: NSPoint) {
        handler?(point)
    }
}

@MainActor
private final class FakeScribeReviewKeyboardMonitor:
    ScribeReviewKeyboardShortcutMonitoring {
    private(set) var commands: Set<ScribeReviewKeyboardCommand> = []
    private(set) var stopCount = 0
    private var handler: ((ScribeReviewKeyboardCommand) -> Void)?

    func start(
        commands: Set<ScribeReviewKeyboardCommand>,
        handler: @escaping (ScribeReviewKeyboardCommand) -> Void
    ) {
        self.commands = commands
        self.handler = handler
    }

    func stop() {
        stopCount += 1
        commands = []
        handler = nil
    }

    func emit(_ command: ScribeReviewKeyboardCommand) {
        handler?(command)
    }
}

@MainActor
struct ScribeNotchCopyInteractionTests {
    @Test
    func outsideClickImmediatelyDismissesCopiedReviewAndRequestsCleanupOnce() {
        let monitor = FakeScribeOutsideClickMonitor()
        let controller = ScribeNotchWindowController(outsideClickMonitor: monitor)
        let result = ScribeResult(requestID: UUID(), text: "Keep this copied review.")
        var cleanupCount = 0
        controller.onOutsideClickAfterCopy = { cleanupCount += 1 }
        controller.viewModel.setReducedMotion(true)
        controller.update(ScribeNotchPresentation(content: .ready(result), pill: .scribed))

        controller.showCopyFeedback("Copied to clipboard")

        #expect(monitor.startCount == 1)

        monitor.emit(NSPoint(x: -100_000, y: -100_000))

        #expect(controller.viewModel.presentation.content == .hidden)
        #expect(cleanupCount == 1)

        monitor.emit(NSPoint(x: -100_000, y: -100_000))
        #expect(cleanupCount == 1)
        controller.close()
    }
}

@MainActor
struct ScribeNotchKeyboardInteractionTests {
    @Test
    func reviewCommandsInvokeTheSameActionsAsTheVisibleControls() {
        let outsideMonitor = FakeScribeOutsideClickMonitor()
        let keyboardMonitor = FakeScribeReviewKeyboardMonitor()
        let controller = ScribeNotchWindowController(
            outsideClickMonitor: outsideMonitor,
            reviewKeyboardMonitor: keyboardMonitor
        )
        let result = ScribeResult(requestID: UUID(), text: "Insert this.")
        var insertCount = 0
        var copyCount = 0
        var discardCount = 0
        controller.viewModel.onInsert = { insertCount += 1 }
        controller.viewModel.onCopy = { copyCount += 1 }
        controller.viewModel.onDiscard = { discardCount += 1 }

        controller.update(
            ScribeNotchPresentation(content: .ready(result), pill: .scribed)
        )

        #expect(keyboardMonitor.commands == [.insert, .copy, .discard])
        keyboardMonitor.emit(.insert)
        keyboardMonitor.emit(.copy)
        keyboardMonitor.emit(.discard)
        #expect(insertCount == 1)
        #expect(copyCount == 1)
        #expect(discardCount == 1)

        controller.update(
            ScribeNotchPresentation(content: .hidden, pill: .hidden)
        )
        keyboardMonitor.emit(.insert)
        #expect(insertCount == 1)
        controller.close()
    }
}

struct ScribeHUDProjectionTests {
    @Test
    func transcriptionFailureUsesTheSameResolvedMessageAsTheNotch() {
        let requestID = UUID()
        let message = "Cadence could not transcribe that request. Try again or use Dictation."

        #expect(ScribeHUDProjection.visualState(
            for: .failed(requestID: requestID, error: .unavailable),
            replacementCompleted: false,
            failureMessage: message
        ) == .error(message: message))
    }

    @Test
    func scribedPillIsReservedForAReadyPolishedResult() {
        let requestID = UUID()
        let result = ScribeResult(requestID: requestID, text: "Polished")

        #expect(ScribeHUDProjection.visualState(
            for: .transcribing(requestID: requestID),
            replacementCompleted: false
        ) == .scribeTranscribing)
        #expect(ScribeHUDProjection.visualState(
            for: .generating(requestID: requestID),
            replacementCompleted: false
        ) == .scribeTranscribing)
        #expect(ScribeHUDProjection.visualState(
            for: .reviewing(result),
            replacementCompleted: false
        ) == .scribeTranscribing)
        #expect(ScribeHUDProjection.visualState(
            for: .reviewing(result),
            replacementCompleted: true
        ) == .scribed)
        #expect(ScribeHUDProjection.visualState(
            for: .failed(requestID: requestID, error: .offline),
            replacementCompleted: true
        ) != .scribed)
        #expect(ScribeHUDProjection.visualState(
            for: .succeeded(requestID: requestID),
            replacementCompleted: true
        ) == .idle)
    }
}

@MainActor
struct ScribeNotchViewModelTests {
    @Test
    func fastProviderResultStillCompletesLiteralTypeOnBeforeReplacement() async {
        let source = "send the finished project update to the whole team today"
        let result = ScribeResult(
            requestID: UUID(),
            text: "Send the finished project update to the entire team today."
        )
        let viewModel = ScribeNotchViewModel()

        viewModel.apply(ScribeNotchPresentation(
            content: .typingTranscript(source, isSlow: false),
            pill: .transcribing
        ))
        try? await Task.sleep(for: .milliseconds(30))
        viewModel.apply(ScribeNotchPresentation(
            content: .replacing(source: source, result: result),
            pill: .transcribing
        ))

        for _ in 0..<80 where !viewModel.completedSourceTypeOn {
            try? await Task.sleep(for: .milliseconds(40))
        }
        #expect(viewModel.completedSourceTypeOn)

        for _ in 0..<80 where viewModel.statusText != "Composed" {
            try? await Task.sleep(for: .milliseconds(40))
        }
        #expect(viewModel.displayedResult == result.text)
        #expect(viewModel.statusText == "Composed")
    }

    @Test
    func reducedMotionReplacementPublishesOneStableReadyState() async {
        let requestID = UUID()
        let result = ScribeResult(requestID: requestID, text: "Send the finished draft today.")
        let viewModel = ScribeNotchViewModel()
        var completionCount = 0
        viewModel.onReplacementCompleted = { completionCount += 1 }
        viewModel.setReducedMotion(true)

        viewModel.apply(ScribeNotchPresentation(
            content: .replacing(source: "send finished draft today", result: result),
            pill: .transcribing
        ))
        await Task.yield()

        #expect(viewModel.displayedSource.isEmpty)
        #expect(viewModel.displayedResult == result.text)
        #expect(viewModel.statusText == "Composed")
        #expect(viewModel.showsReviewActions)
        #expect(completionCount == 1)
    }

    @Test
    func clipboardFeedbackIsPublishedInsideTheNotchWindowLayer() {
        let viewModel = ScribeNotchViewModel()
        viewModel.setReducedMotion(true)

        viewModel.showFeedback("Copied to clipboard")

        #expect(viewModel.feedbackMessage == "Copied to clipboard")
        #expect(viewModel.feedbackOpacity == 1)

        viewModel.apply(ScribeNotchPresentation(content: .hidden, pill: .listening))
        #expect(viewModel.feedbackMessage.isEmpty)
        #expect(viewModel.feedbackOpacity == 0)
    }
}

struct ScribeHUDRestorationPolicyTests {
    @Test
    func activeDictationKeepsOwnershipOfTheHUD() {
        #expect(ScribeHUDRestorationAction.resolve(
            requiredPermissionsGranted: true,
            isDictationIdle: false
        ) == .leaveCurrentHUD)
    }

    @Test
    func idleDictationRestoresTheAppropriateRestingState() {
        #expect(ScribeHUDRestorationAction.resolve(
            requiredPermissionsGranted: true,
            isDictationIdle: true
        ) == .showReadyLogo)
        #expect(ScribeHUDRestorationAction.resolve(
            requiredPermissionsGranted: false,
            isDictationIdle: true
        ) == .showIdle)
    }
}
