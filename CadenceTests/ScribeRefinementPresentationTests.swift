import AppKit
import Foundation
import Testing
@testable import Cadence

struct ScribeRefinementKeyboardPolicyTests {
    @Test
    func refinementOnlyCapturesEscapeAcrossRecordingAndGeneration() {
        for content in [
            ScribeNotchContent.hidden,
            .transcribing,
            .typingTranscript("Make it shorter", isSlow: false),
            .typingTranscript("Make it shorter", isSlow: true)
        ] {
            #expect(ScribeReviewKeyboardPolicy.commands(for: content, isRefining: true) == [.discard])
            #expect(ScribeReviewKeyboardPolicy.commands(for: content).isEmpty)
        }
    }
}

struct ScribeRefinementInterruptionTests {
    @Test
    func sameDraftWaitsForDictationAndItsTerminalFeedbackToFinish() {
        let actionID = UUID()
        let interruption = ScribeRefinementInterruption(actionID: actionID)
        let review = ScribeSessionState.reviewing(.init(requestID: actionID, text: "Accepted draft"))

        for (state, hud) in [
            (DictationSessionState.listening, HUDVisualState.recording(triggerMode: .holdToTalk, showsHint: false)),
            (.finalizing, .transcribing),
            (.inserting, .inserting),
            (.idle, .success),
            (.idle, .copied),
            (.error("Try again"), .idle)
        ] {
            #expect(interruption.resolution(
                dictationState: state, dictationHUD: hud,
                activeActionID: actionID, scribeState: review, isRefining: false
            ) == .wait)
        }
        #expect(interruption.resolution(
            dictationState: .idle, dictationHUD: .idle,
            activeActionID: actionID, scribeState: review, isRefining: false
        ) == .restoreReview)
    }

    @Test
    func cancellationMustFinishBeforeTheRetainedDraftCanReappear() {
        let actionID = UUID()
        let interruption = ScribeRefinementInterruption(actionID: actionID)
        #expect(interruption.resolution(
            dictationState: .idle, dictationHUD: .idle,
            activeActionID: actionID, scribeState: .generating(requestID: actionID), isRefining: true
        ) == .wait)
    }

    @Test
    func dismissedOrReplacedComposeActionsCannotRestoreAnOldReview() {
        let actionID = UUID()
        let interruption = ScribeRefinementInterruption(actionID: actionID)
        for currentActionID in [nil, UUID()] as [UUID?] {
            #expect(interruption.resolution(
                dictationState: .idle, dictationHUD: .idle,
                activeActionID: currentActionID,
                scribeState: .reviewing(.init(requestID: actionID, text: "Old draft")),
                isRefining: false
            ) == .forget)
        }
        #expect(interruption.resolution(
            dictationState: .idle, dictationHUD: .idle,
            activeActionID: actionID, scribeState: .cancelled(requestID: actionID), isRefining: false
        ) == .forget)
    }
}

@MainActor
struct ScribeRefinementPresentationTests {
    @Test
    func hiddenRefinementRecordingRoutesEscapeToKeepDraftAndStopsOnClose() {
        let keyboard = RefinementKeyboardMonitor()
        let controller = ScribeNotchWindowController(
            outsideClickMonitor: RefinementOutsideClickMonitor(),
            reviewKeyboardMonitor: keyboard
        )
        var cancellationCount = 0
        var discardCount = 0
        controller.viewModel.onCancelRefinement = { cancellationCount += 1 }
        controller.viewModel.onDiscard = { discardCount += 1 }
        controller.viewModel.updateRefinement(
            canRefineReviewedDraft: false,
            canUndoRefinement: false,
            unavailableReason: nil,
            isRefining: true
        )

        controller.update(.init(content: .hidden, pill: .listening))
        #expect(keyboard.commands == [.discard])
        #expect(controller.viewModel.isRefining)
        keyboard.send(.discard)
        #expect(cancellationCount == 1)
        #expect(discardCount == 0)

        controller.close()
        #expect(keyboard.commands.isEmpty)
        #expect(!controller.viewModel.isRefining)
    }

    @Test
    func retainedReviewPublishesFailureWithoutReplacingAcceptedText() {
        let model = ScribeNotchViewModel()
        let result = ScribeResult(requestID: UUID(), text: "Accepted draft.")
        let presentation = ScribeNotchPresentation(content: .ready(result), pill: .scribed)
        model.apply(presentation)

        // Acquisition can fail before the visible state changes. The repeated
        // review presentation must still publish its recovery explanation.
        model.updateRefinement(
            canRefineReviewedDraft: true,
            canUndoRefinement: false,
            unavailableReason: nil,
            isRefining: false,
            reviewNotice: "Refinement could not start. Your draft is still here.",
            lastInstruction: "Make it shorter"
        )
        model.apply(presentation)

        #expect(model.displayedResult == result.text)
        #expect(model.statusText == "Draft kept")
        #expect(model.reviewNotice != nil)
        #expect(model.lastRefinementInstruction == "Make it shorter")
        #expect(model.showsReviewActions)
    }

    @Test
    func unchangedSelectionHasHonestReviewStatusAndNoInsert() {
        let model = ScribeNotchViewModel()
        model.updateSelectedTextReviewSource(.init(
            id: UUID(), text: "Original sentence.", includedUTF8Bytes: 18,
            isExcluded: false, isUnchanged: true
        ))
        model.updateRefinement(
            canRefineReviewedDraft: false, canUndoRefinement: false,
            unavailableReason: nil, isRefining: false,
            reviewNotice: "The rewrite matches your selected text."
        )
        model.apply(.init(content: .ready(.init(requestID: UUID(), text: "Original sentence.")), pill: .scribed))

        #expect(model.statusText == "No changes made")
        #expect(!model.permitsReviewedInsertion)
        #expect(model.reviewNotice == "The rewrite matches your selected text.")
    }

    @Test
    func refinementStartupKeepsTextButDisablesDraftDeliveryBeforeRecording() {
        let model = ScribeNotchViewModel()
        model.apply(.init(
            content: .ready(.init(requestID: UUID(), text: "Accepted draft.")),
            pill: .scribed
        ))
        model.updateRefinement(
            canRefineReviewedDraft: false,
            canUndoRefinement: false,
            unavailableReason: nil,
            isRefining: true
        )

        #expect(model.displayedResult == "Accepted draft.")
        #expect(!model.showsReviewActions)
        #expect(model.allowsInteraction)
        #expect(model.statusText == "Preparing refinement")
        #expect(ScribeReviewKeyboardPolicy.commands(
            for: model.presentation.content, isRefining: model.isRefining
        ) == [.discard])
    }

    @Test
    func cloudReviewKeepsItsDraftAndExplainsDisabledRefinement() {
        let model = ScribeNotchViewModel()
        let reason = "Voice refinement is available for Apple Intelligence drafts only."
        model.updateRefinement(
            canRefineReviewedDraft: false,
            canUndoRefinement: false,
            unavailableReason: reason,
            isRefining: false
        )
        model.apply(.init(
            content: .ready(.init(requestID: UUID(), text: "Cloud draft.")),
            pill: .scribed
        ))

        #expect(model.showsRefinementActions)
        #expect(!model.canRefineReviewedDraft)
        #expect(model.refinementHelp == reason)
        #expect(model.displayedResult == "Cloud draft.")
    }
}

@MainActor
private final class RefinementKeyboardMonitor: ScribeReviewKeyboardShortcutMonitoring {
    private(set) var commands: Set<ScribeReviewKeyboardCommand> = []
    private var handler: ((ScribeReviewKeyboardCommand) -> Void)?

    func start(
        commands: Set<ScribeReviewKeyboardCommand>,
        handler: @escaping (ScribeReviewKeyboardCommand) -> Void
    ) {
        self.commands = commands
        self.handler = handler
    }

    func stop() {
        commands = []
        handler = nil
    }

    func send(_ command: ScribeReviewKeyboardCommand) {
        handler?(command)
    }
}

@MainActor
private final class RefinementOutsideClickMonitor: ScribeOutsideClickMonitoring {
    func start(handler: @escaping (NSPoint) -> Void) {}
    func stop() {}
}
