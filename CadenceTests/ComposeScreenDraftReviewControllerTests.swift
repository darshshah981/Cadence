import CoreGraphics
import Foundation
import Testing
@testable import Cadence

@MainActor
struct ComposeScreenDraftReviewControllerTests {
    @Test
    func explicitApprovalsPrecedeCaptureAndLocalGeneration() async {
        let fixture = Fixture()
        #expect(fixture.review.begin(fixture.candidate))
        #expect(fixture.review.phase == .awaitingCaptureApproval)
        #expect(fixture.picker.callCount == 0)
        #expect(await fixture.provider.callCount == 0)

        fixture.review.approveLocalReading()
        await fixture.waitForProviderApproval()
        guard case let .awaitingProviderApproval(preview) = fixture.review.phase else {
            Issue.record("Expected separate OCR-text provider approval")
            return
        }
        #expect(preview == "Can we meet Thursday?")
        #expect(await fixture.provider.callCount == 0)
        #expect(fixture.picker.callCount == 1)

        fixture.review.approveProviderUse()
        await fixture.waitForReady()
        #expect(fixture.review.copyableDraft() == "Thursday works for me.")
        #expect(await fixture.provider.callCount == 1)
        #expect(await fixture.provider.lastInput?.userMessage.contains("Can we meet Thursday?") == true)
        fixture.review.cancel()
        #expect(fixture.review.phase == .idle)
    }

    @Test
    func cancellingSystemPickerQuietlyReturnsToTheOriginalReview() async {
        let fixture = Fixture()
        fixture.picker.nextError = .cancelled
        #expect(fixture.review.begin(fixture.candidate))
        fixture.review.approveLocalReading()
        await fixture.waitForIdleAfterChoice()
        #expect(fixture.picker.callCount == 1)
        #expect(await fixture.provider.callCount == 0)
        #expect(fixture.review.begin(fixture.candidate))
        #expect(fixture.review.phase == .awaitingCaptureApproval)
    }

    @Test
    func revocationBeforeProviderApprovalStopsTransmission() async {
        let fixture = Fixture()
        #expect(fixture.review.begin(fixture.candidate))
        fixture.review.approveLocalReading()
        await fixture.waitForProviderApproval()
        fixture.consent.revoke()
        fixture.review.approveProviderUse()
        #expect(fixture.review.phase == .unavailable)
        #expect(await fixture.provider.callCount == 0)
    }

    @Test
    func actionSwitchDuringGenerationCannotPublishOrCopy() async {
        let fixture = Fixture()
        await fixture.provider.suspendNextResult()
        #expect(fixture.review.begin(fixture.candidate))
        fixture.review.approveLocalReading()
        await fixture.waitForProviderApproval()
        fixture.review.approveProviderUse()
        await fixture.provider.waitForCall()
        fixture.currentActionID = nil
        await fixture.provider.finishResult()
        await fixture.waitForUnavailable()
        #expect(fixture.review.copyableDraft() == nil)
    }

    @Test
    func expiryOrModelWrapperCannotBecomeCopyable() async {
        let expired = Fixture()
        #expect(expired.review.begin(expired.candidate))
        expired.review.approveLocalReading()
        await expired.waitForProviderApproval()
        expired.review.approveProviderUse()
        await expired.waitForReady()
        expired.clock = expired.clock.addingTimeInterval(181)
        #expect(expired.review.copyableDraft() == nil)

        let wrapped = Fixture()
        await wrapped.provider.setResult("Sure, here's the draft: Thursday works for me.")
        #expect(wrapped.review.begin(wrapped.candidate))
        wrapped.review.approveLocalReading()
        await wrapped.waitForProviderApproval()
        wrapped.review.approveProviderUse()
        await wrapped.waitForUnavailable()
        #expect(wrapped.review.copyableDraft() == nil)
    }

    @MainActor
    private final class Fixture {
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        var currentActionID: UUID?
        let candidate: ScribeScreenContextReviewCandidate
        let picker: Picker
        let provider = Provider()
        lazy var consent = ComposeScreenContextConsentController(
            actionIsCurrent: { [unowned self] in self.currentActionID == $0 },
            captureIsCurrent: { [unowned self] in self.candidate.capture == $0 },
            providerIsCurrent: { [unowned self] in
                self.candidate.providerAction.actionIdentity == $0.actionIdentity
            },
            now: { [unowned self] in self.clock }
        )
        lazy var screen = ComposeScreenContextActionController(
            picker: picker, captureAdapter: Capture(), ocr: OCR(),
            policy: { [unowned self] in
                self.consent.policy(
                    actionID: self.candidate.request.id,
                    capture: self.candidate.capture
                )
            },
            permissions: { .init(accessibility: true, screenRecording: true) },
            actionIsCurrent: { [unowned self] in self.currentActionID == $0 },
            captureIsCurrent: { [unowned self] in self.candidate.capture == $0 },
            focusedWindowFrame: { [unowned self] _ in self.picker.window.expectedFrame },
            targetIsCurrent: { [unowned self] _ in self.currentActionID != nil },
            now: { [unowned self] in self.clock }
        )
        lazy var review = ComposeScreenDraftReviewController(
            consent: consent, screen: screen,
            candidateIsCurrent: { [unowned self] in
                self.currentActionID == $0.request.id
                    && self.candidate.capture == $0.capture
                    && self.candidate.providerAction.actionIdentity
                        == $0.providerAction.actionIdentity
            },
            authorizeProviderDispatch: { _ in true },
            permissions: { .init(accessibility: true, screenRecording: true) },
            now: { [unowned self] in self.clock }
        )

        init() {
            let actionID = UUID()
            let captureID = UUID()
            let process = ApplicationProcessIdentity(
                processIdentifier: 42, bundleIdentifier: "test.editor",
                bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
                incarnation: UUID(), launchDate: Date(timeIntervalSince1970: 100)
            )
            let capture = ScribeContextSnapshot(
                id: captureID,
                target: .init(processIdentifier: 42, bundleIdentifier: "test.editor"),
                selectedText: "",
                applicationTarget: .init(
                    id: captureID, process: process, identityRevision: 1,
                    captureRevision: 1, source: .scribeAccessibility
                )
            )
            let request = ScribeRequest(
                id: actionID, intent: .compose,
                spokenTranscript: "Reply that Thursday works"
            )
            let action = ScribeProviderActionSnapshot(
                provider: provider, destination: .legacyLocal,
                configurationID: UUID(), libraryRevision: 1,
                selectedModelID: "local"
            )
            candidate = .init(request: request, capture: capture, providerAction: action)
            currentActionID = actionID
            let window = ComposeScreenWindowIdentity(
                windowID: 7, processIdentifier: 42, bundleIdentifier: "test.editor",
                processIdentity: process,
                expectedFrame: .init(x: 20, y: 30, width: 100, height: 40)
            )
            picker = Picker(window: window)
        }

        func waitForProviderApproval() async {
            for _ in 0..<100 {
                if case .awaitingProviderApproval = review.phase { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Screen reading did not reach provider approval")
        }

        func waitForReady() async {
            for _ in 0..<100 {
                if case .ready = review.phase { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Screen draft did not become ready")
        }

        func waitForUnavailable() async {
            for _ in 0..<100 {
                if review.phase == .unavailable { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Screen draft did not fail closed")
        }

        func waitForIdleAfterChoice() async {
            for _ in 0..<100 {
                if picker.callCount == 1 && review.phase == .idle { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("System picker cancellation did not restore review")
        }
    }
}

@MainActor
private final class Picker: ComposeScreenWindowChoosing {
    let window: ComposeScreenWindowIdentity
    private(set) var callCount = 0
    var nextError: ComposeScreenWindowPickerError?
    init(window: ComposeScreenWindowIdentity) { self.window = window }
    func chooseWindow(actionID _: UUID, capture _: ScribeContextSnapshot,
                      expectedFrame _: CGRect) async throws -> ComposeScreenWindowIdentity {
        callCount += 1
        if let nextError {
            self.nextError = nil
            throw nextError
        }
        return window
    }
}

private actor Capture: ComposeScreenCapturing {
    func capture(window _: ComposeScreenWindowIdentity,
                 timeoutMilliseconds _: Int) async throws -> ComposeScreenImage {
        .init(width: 100, height: 40)
    }
}

private actor OCR: ComposeScreenOCRRecognizing {
    func recognize(image _: ComposeScreenImage, maximumLines _: Int,
                   timeoutMilliseconds _: Int) async throws -> ComposeOCRResult {
        .init(lines: [.init(
            text: "Can we meet Thursday?", confidence: 0.95,
            boundingBox: .init(x: 0, y: 0, width: 1, height: 1)
        )], isClipped: false)
    }
}

private actor Provider: ScribeProvider {
    nonisolated let capabilities: ScribeProviderCapabilities = [.semanticGeneration]
    private(set) var callCount = 0
    private(set) var lastInput: ProviderSafeScribeInput?
    private var result = "Thursday works for me."
    private var suspend = false
    private var pending: CheckedContinuation<Void, Never>?

    func setResult(_ text: String) { result = text }
    func suspendNextResult() { suspend = true }
    func waitForCall() async {
        for _ in 0..<100 {
            if callCount > 0 { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func finishResult() { pending?.resume(); pending = nil }
    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        callCount += 1
        lastInput = request.input
        if suspend {
            suspend = false
            await withCheckedContinuation { pending = $0 }
        }
        return .init(requestID: request.id, text: result)
    }
}
