import Foundation
import OSLog

private let scribeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Scribe"
)

private struct ScribeCapturedAudio: Sendable {
    let chunk: AudioChunk
    let level: Double
}

enum ScribeCoordinatorError: Error, Equatable, Sendable {
    case invalidState
    case insertionAlreadyCompleted
}

enum ScribeSessionFailure: Equatable, Sendable {
    case provider(ScribeProviderError)
    case context(ScribeContextError)
    case voiceSessionBusy(VoiceSessionKind)
    case transcription
    case uncertainInsertion
}

@MainActor
final class ScribeCoordinator {
    var onStateChange: ((ScribeSessionState) -> Void)?
    var onAudioLevel: ((Double) -> Void)?

    private(set) var state = ScribeSessionState.idle {
        didSet { onStateChange?(state) }
    }
    private(set) var literalTranscript: String?
    private(set) var reviewedResult: ScribeResult?
    private(set) var failure: ScribeSessionFailure?
    private(set) var activeRequestID: UUID?

    private let audioCaptureService: AudioCaptureServing
    private let transcriptionEngine: TranscriptionEngine
    private let provider: any ScribeProvider
    private let contextService: ScribeContextServing
    private let textInsertionService: GuardedTextInsertionServing
    private let sessionArbiter: VoiceSessionArbiter
    private let personalizationStore: PersonalizationStore
    private let generationTimeout: Duration

    private var activeIntent: ScribeIntent?
    private var activeCapture: ScribeContextSnapshot?
    private var activeRequest: ScribeRequest?
    private var voiceLease: VoiceSessionLease?
    private var generationTask: Task<Void, Never>?
    private var generation = 0
    private var insertionCompleted = false
    private var audioContinuation: AsyncStream<ScribeCapturedAudio>.Continuation?
    private var audioIngestionTask: Task<Void, Never>?

    init(
        audioCaptureService: AudioCaptureServing,
        transcriptionEngine: TranscriptionEngine,
        provider: any ScribeProvider,
        contextService: ScribeContextServing,
        textInsertionService: GuardedTextInsertionServing,
        sessionArbiter: VoiceSessionArbiter,
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        generationTimeout: Duration = .seconds(30)
    ) {
        self.audioCaptureService = audioCaptureService
        self.transcriptionEngine = transcriptionEngine
        self.provider = provider
        self.contextService = contextService
        self.textInsertionService = textInsertionService
        self.sessionArbiter = sessionArbiter
        self.personalizationStore = personalizationStore
        self.generationTimeout = generationTimeout
    }

    func begin(intent: ScribeIntent) async throws {
        guard state == .idle || isTerminalState else {
            throw ScribeCoordinatorError.invalidState
        }

        resetTransientState()
        generation += 1
        let requestID = UUID()
        activeRequestID = requestID
        activeIntent = intent

        do {
            voiceLease = try sessionArbiter.acquire(for: .scribe)
        } catch let error as VoiceSessionArbiterError {
            if case let .busy(kind) = error {
                failure = .voiceSessionBusy(kind)
            }
            throw error
        }

        do {
            activeCapture = try contextService.capture(for: intent)
            try await transcriptionEngine.startSession()
            let (stream, continuation) = AsyncStream.makeStream(
                of: ScribeCapturedAudio.self,
                bufferingPolicy: .bufferingOldest(256)
            )
            audioContinuation = continuation
            audioIngestionTask = Task { [weak self, transcriptionEngine] in
                for await capturedAudio in stream {
                    guard let self, !Task.isCancelled else { return }
                    await transcriptionEngine.appendAudio(capturedAudio.chunk)
                    self.onAudioLevel?(capturedAudio.level)
                }
            }
            try audioCaptureService.startCapture { [continuation] chunk, level in
                continuation.yield(ScribeCapturedAudio(chunk: chunk, level: level))
            }
            state = .listening(requestID: requestID, intent: intent)
        } catch {
            await finishAudioIngestion(cancel: true)
            await transcriptionEngine.cancelSession()
            releaseVoiceLease()
            clearContext()
            throw error
        }
    }

    func finishRecording() async {
        guard case .listening = state,
              let intent = activeIntent,
              let capture = activeCapture,
              let requestID = activeRequestID else { return }

        let runGeneration = generation
        let metrics = audioCaptureService.stopCapture()
        await finishAudioIngestion(cancel: false)
        guard runGeneration == generation else { return }
        state = .transcribing(requestID: requestID)

        do {
            let transcript = try await transcriptionEngine.finishSession(metrics: metrics)
                .cleanedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            guard !transcript.isEmpty else {
                throw ScribeProviderError.emptyResult
            }

            literalTranscript = transcript
            let personalization = personalizationStore.load()
            let expandedTranscript = ShortcutExpansionService.expand(
                transcript,
                bundleIdentifier: capture.target.bundleIdentifier,
                shortcuts: personalization.shortcuts
            )
            let style = StyleProfileResolver.resolve(
                bundleIdentifier: capture.target.bundleIdentifier,
                profiles: personalization.styleProfiles
            ).map(ScribeStyleInstructions.init(profile:))
            let request = ScribeRequest(
                id: requestID,
                intent: intent,
                spokenTranscript: expandedTranscript,
                context: capture.scope == .selectedText
                    ? ScribeRequestContext(selectedText: capture.selectedText)
                    : nil,
                style: style
            )
            activeRequest = request
            await startGeneration(request, generation: runGeneration)
        } catch let error as ScribeProviderError {
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            setProviderFailure(error, requestID: requestID)
        } catch {
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            failure = .transcription
            state = .failed(requestID: requestID, error: .unavailable)
            scribeLogger.error("Scribe transcription failed category=transcription")
        }
    }

    func retryGeneration() async {
        guard let request = activeRequest else { return }
        generation += 1
        await startGeneration(request, generation: generation)
    }

    func useLiteralTranscript() {
        guard let requestID = activeRequestID,
              let literalTranscript,
              !literalTranscript.isEmpty else { return }
        let result = ScribeResult(requestID: requestID, text: literalTranscript)
        reviewedResult = result
        failure = nil
        state = .reviewing(result)
    }

    func insertReviewedResult() async throws {
        guard !insertionCompleted else {
            throw ScribeCoordinatorError.insertionAlreadyCompleted
        }
        guard let result = reviewedResult,
              let capture = activeCapture else {
            throw ScribeCoordinatorError.invalidState
        }

        do {
            guard try contextService.verifyTarget(for: capture) else {
                throw ScribeContextError.targetChanged
            }
        } catch let error as ScribeContextError {
            failure = .context(error)
            throw error
        }

        state = .inserting(requestID: result.requestID)
        do {
            _ = try await textInsertionService.insertGuarded(result.text)
            insertionCompleted = true
            state = .succeeded(requestID: result.requestID)
            clearContext()
        } catch GuardedTextInsertionError.uncertainPartialInsertion {
            failure = .uncertainInsertion
            state = .failed(requestID: result.requestID, error: .unavailable)
            throw GuardedTextInsertionError.uncertainPartialInsertion
        }
    }

    func cancel() async {
        let cancelledRequestID = activeRequestID
        generation += 1
        generationTask?.cancel()
        generationTask = nil

        if case .listening = state {
            _ = audioCaptureService.stopCapture()
        }
        await finishAudioIngestion(cancel: true)
        await transcriptionEngine.cancelSession()
        releaseVoiceLease()
        clearContext()
        activeRequest = nil
        reviewedResult = nil
        literalTranscript = nil
        failure = nil
        state = .cancelled(requestID: cancelledRequestID)
    }

    private func startGeneration(_ request: ScribeRequest, generation expectedGeneration: Int) async {
        state = .generating(requestID: request.id)
        failure = nil

        let task = Task { [provider, generationTimeout] in
            do {
                let result = try await Self.generate(
                    request,
                    provider: provider,
                    timeout: generationTimeout
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.reviewedResult = result
                    self.failure = nil
                    self.state = .reviewing(result)
                }
            } catch is CancellationError {
                return
            } catch let error as ScribeProviderError {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.setProviderFailure(error, requestID: request.id)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == expectedGeneration else { return }
                    self.setProviderFailure(.unavailable, requestID: request.id)
                }
            }
        }
        generationTask = task
        await task.value
        if generation == expectedGeneration {
            generationTask = nil
        }
    }

    private nonisolated static func generate(
        _ request: ScribeRequest,
        provider: any ScribeProvider,
        timeout: Duration
    ) async throws -> ScribeResult {
        try await withThrowingTaskGroup(of: ScribeResult.self) { group in
            group.addTask { try await provider.generate(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ScribeProviderError.timedOut
            }
            guard let first = try await group.next() else {
                throw ScribeProviderError.unavailable
            }
            group.cancelAll()
            return first
        }
    }

    private func setProviderFailure(_ error: ScribeProviderError, requestID: UUID) {
        failure = .provider(error)
        state = .failed(requestID: requestID, error: error)
    }

    private func releaseVoiceLease() {
        guard let voiceLease else { return }
        sessionArbiter.release(voiceLease)
        self.voiceLease = nil
    }

    private func clearContext() {
        guard let activeCapture else { return }
        contextService.clear(activeCapture)
        self.activeCapture = nil
    }

    private func resetTransientState() {
        generationTask?.cancel()
        generationTask = nil
        clearContext()
        activeIntent = nil
        activeRequest = nil
        activeRequestID = nil
        literalTranscript = nil
        reviewedResult = nil
        failure = nil
        insertionCompleted = false
    }

    private func finishAudioIngestion(cancel: Bool) async {
        audioContinuation?.finish()
        audioContinuation = nil
        if cancel {
            audioIngestionTask?.cancel()
        }
        await audioIngestionTask?.value
        audioIngestionTask = nil
    }

    private var isTerminalState: Bool {
        switch state {
        case .succeeded, .cancelled, .failed:
            return true
        default:
            return false
        }
    }
}
