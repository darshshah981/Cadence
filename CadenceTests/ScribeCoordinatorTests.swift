import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeCoordinatorTests {
    @Test
    func voiceSessionArbiterRejectsOverlappingPipelines() throws {
        let arbiter = VoiceSessionArbiter()
        let dictation = try arbiter.acquire(for: .dictation)

        #expect(arbiter.activeKind == .dictation)
        #expect(throws: VoiceSessionArbiterError.busy(.dictation)) {
            try arbiter.acquire(for: .scribe)
        }

        arbiter.release(dictation)
        #expect(arbiter.activeKind == nil)
        #expect(try arbiter.acquire(for: .meeting).kind == .meeting)
    }

    @Test
    func composeRunsThroughReviewAndInsertsExactlyOnce() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("A polished update.")])

        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.state == .reviewing(
            ScribeResult(requestID: fixture.coordinator.activeRequestID!, text: "A polished update.")
        ))
        #expect(fixture.arbiter.activeKind == nil)

        try await fixture.coordinator.insertReviewedResult()
        #expect(fixture.context.insertedTexts == ["A polished update."])
        #expect(fixture.context.clearedCaptureIDs.count == 1)

        await #expect(throws: ScribeCoordinatorError.insertionAlreadyCompleted) {
            try await fixture.coordinator.insertReviewedResult()
        }
    }

    @Test
    func respondAndEditSendOnlySelectedTextToProvider() async throws {
        for intent in [ScribeIntent.respond, .edit] {
            let provider = CapturingScribeProvider(resultText: "Result")
            let fixture = ScribeCoordinatorFixture(provider: provider, selectedText: "Selected context")

            try await fixture.coordinator.begin(intent: intent)
            await fixture.coordinator.finishRecording()

            let request = await provider.requests.first
            #expect(request?.intent == intent)
            #expect(request?.context?.selectedText == "Selected context")
        }
    }

    @Test
    func requestAppliesLocalShortcutAndStyleWithoutSendingAppIdentity() async throws {
        let suiteName = "ScribePersonalization.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PersonalizationStore(defaults: defaults)
        try store.save(PersonalizationLibrary(
            shortcuts: [PersonalShortcut(trigger: "Spoken request", template: "Expanded locally")],
            styleProfiles: [WritingStyleProfile(
                name: "TextEdit profile",
                appBundleIdentifier: "com.apple.TextEdit",
                tone: .direct,
                length: .concise,
                punctuation: .minimal,
                formatting: .plainText
            )]
        ))
        let provider = CapturingScribeProvider(resultText: "Result")
        let fixture = ScribeCoordinatorFixture(provider: provider, personalizationStore: store)

        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()

        let request = await provider.requests.first
        #expect(request?.spokenTranscript == "Expanded locally")
        #expect(request?.style == ScribeStyleInstructions(
            profile: WritingStyleProfile(
                name: "Ignored at provider boundary",
                tone: .direct,
                length: .concise,
                punctuation: .minimal,
                formatting: .plainText
            )
        ))
    }

    @Test
    func providerTimeoutRetainsLiteralTranscriptForRetryAndFallback() async throws {
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [
                .delayedSuccess("Too late", .seconds(10)),
                .success("Recovered draft")
            ],
            generationTimeout: .milliseconds(10)
        )

        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.literalTranscript == "Spoken request")
        #expect(fixture.coordinator.failure == .provider(.timedOut))

        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.reviewedResult?.text == "Recovered draft")
    }

    @Test
    func targetChangePreventsInsertionAndKeepsDraftAvailable() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Draft")])
        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()
        fixture.context.shouldVerify = false

        await #expect(throws: ScribeContextError.targetChanged) {
            try await fixture.coordinator.insertReviewedResult()
        }

        #expect(fixture.context.insertedTexts.isEmpty)
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
    }

    @Test
    func cancellationDuringGenerationIgnoresLateCompletionAndClearsTransientState() async throws {
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.delayedSuccess("Late", .seconds(10))],
            generationTimeout: .seconds(20)
        )
        try await fixture.coordinator.begin(intent: .compose)

        let finishing = Task { await fixture.coordinator.finishRecording() }
        await Task.yield()
        await fixture.coordinator.cancel()
        await finishing.value

        if case .cancelled = fixture.coordinator.state {
            // Expected terminal state.
        } else {
            Issue.record("Expected cancellation to remain terminal")
        }
        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.context.clearedCaptureIDs.count == 1)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func concurrentBeginIsRejectedWhileEngineIsStarting() async throws {
        let engine = ControllableScribeEngine(suspendsStart: true)
        let fixture = ScribeCoordinatorFixture(engine: engine)
        let firstBegin = Task { try await fixture.coordinator.begin(intent: .compose) }
        await engine.waitForStartCount(1)

        await #expect(throws: ScribeCoordinatorError.invalidState) {
            try await fixture.coordinator.begin(intent: .edit)
        }

        await engine.resumeStart()
        try await firstBegin.value
        await fixture.coordinator.cancel()
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func repeatedStopRunsOnlyOneFinalTranscription() async throws {
        let engine = ControllableScribeEngine(suspendsFinish: true)
        let fixture = ScribeCoordinatorFixture(engine: engine)
        try await fixture.coordinator.begin(intent: .compose)

        let firstStop = Task { await fixture.coordinator.finishRecording() }
        await engine.waitForFinishCount(1)
        await fixture.coordinator.finishRecording()

        let finishCount = await engine.finishCount
        #expect(finishCount == 1)
        await engine.resumeFinish()
        await firstStop.value
    }

    @Test
    func cancellingIntentPickerDiscardsPinnedTarget() async throws {
        let fixture = ScribeCoordinatorFixture()
        try fixture.coordinator.prepareTarget()

        await fixture.coordinator.cancel()

        #expect(fixture.context.discardPreparedTargetCount == 1)
    }
}

@MainActor
private final class ScribeCoordinatorFixture {
    let arbiter = VoiceSessionArbiter()
    let context: StubScribeContextService
    let audio = StubAudioCaptureService()
    let engine: any TranscriptionEngine
    let coordinator: ScribeCoordinator

    init(
        providerResponses: [MockScribeProvider.Response] = [.success("Draft")],
        provider: (any ScribeProvider)? = nil,
        selectedText: String = "Selected context",
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        engine: (any TranscriptionEngine)? = nil,
        generationTimeout: Duration = .seconds(5)
    ) {
        context = StubScribeContextService(selectedText: selectedText)
        self.engine = engine ?? StubScribeTranscriptionEngine(text: "Spoken request")
        coordinator = ScribeCoordinator(
            audioCaptureService: audio,
            transcriptionEngine: self.engine,
            provider: provider ?? MockScribeProvider(responses: providerResponses),
            contextService: context,
            sessionArbiter: arbiter,
            personalizationStore: personalizationStore,
            generationTimeout: generationTimeout
        )
    }
}

private actor ControllableScribeEngine: TranscriptionEngine {
    private let suspendsStart: Bool
    private let suspendsFinish: Bool
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var finishCount = 0

    init(suspendsStart: Bool = false, suspendsFinish: Bool = false) {
        self.suspendsStart = suspendsStart
        self.suspendsFinish = suspendsFinish
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws {
        startCount += 1
        if suspendsStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
    }
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        finishCount += 1
        if suspendsFinish {
            await withCheckedContinuation { finishContinuation = $0 }
        }
        return FinalTranscript(rawText: "Spoken request", cleanedText: "Spoken request", duration: metrics.duration)
    }
    func cancelSession() async {}
    func statusSummary() async -> String { "Ready" }

    func waitForStartCount(_ expected: Int) async {
        while startCount < expected { await Task.yield() }
    }

    func waitForFinishCount(_ expected: Int) async {
        while finishCount < expected { await Task.yield() }
    }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class StubScribeContextService: ScribeContextServing {
    private let selectedText: String
    var shouldVerify = true
    private(set) var clearedCaptureIDs: [UUID] = []
    private(set) var insertedTexts: [String] = []
    private(set) var discardPreparedTargetCount = 0

    init(selectedText: String) {
        self.selectedText = selectedText
    }

    func prepareTarget() throws {}

    func capture(for intent: ScribeIntent) throws -> ScribeContextSnapshot {
        ScribeContextSnapshot(
            target: ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit"),
            scope: intent.contextScope,
            selectedText: intent.requiresSelectedText ? selectedText : "",
            verificationToken: "window-a"
        )
    }

    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool {
        guard shouldVerify else { throw ScribeContextError.targetChanged }
        return true
    }

    func insert(_ text: String, for capture: ScribeContextSnapshot) throws -> Bool {
        guard try verifyTarget(for: capture) else { return false }
        insertedTexts.append(text)
        return true
    }

    func clear(_ capture: ScribeContextSnapshot) {
        clearedCaptureIDs.append(capture.id)
    }

    func discardPreparedTarget() { discardPreparedTargetCount += 1 }
}

private final class StubAudioCaptureService: AudioCaptureServing {
    private(set) var isCapturing = false

    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws {
        isCapturing = true
        chunkHandler(AudioChunk(samples: [0.1], frameCount: 1, sampleRate: 16_000), 0.1)
    }

    func stopCapture() -> AudioCaptureSessionMetrics {
        isCapturing = false
        return AudioCaptureSessionMetrics(
            duration: 1,
            frameCount: 16_000,
            sampleRate: 16_000,
            speechDetected: true,
            speechFrameCount: 16_000,
            peakLevel: 0.5
        )
    }
}

private actor StubScribeTranscriptionEngine: TranscriptionEngine {
    let text: String

    init(text: String) { self.text = text }
    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {}
    func isPrepared() async -> Bool { true }
    func prepare() async throws {}
    func startSession() async throws {}
    func appendAudio(_ chunk: AudioChunk) async {}
    func previewTranscript() async -> PreviewTranscript? { nil }
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        FinalTranscript(rawText: text, cleanedText: text, duration: metrics.duration)
    }
    func cancelSession() async {}
    func statusSummary() async -> String { "Ready" }
}

private actor CapturingScribeProvider: ScribeProvider {
    nonisolated let capabilities = ScribeProviderCapabilities.mock
    private(set) var requests: [ScribeRequest] = []
    let resultText: String

    init(resultText: String) { self.resultText = resultText }

    func generate(_ request: ScribeRequest) async throws -> ScribeResult {
        requests.append(request)
        return ScribeResult(requestID: request.id, text: resultText)
    }
}
