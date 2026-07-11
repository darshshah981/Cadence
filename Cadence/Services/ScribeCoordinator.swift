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

private final class ScribeGenerationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ScribeResult, Error>?
    private var providerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false
    private var terminalResult: Result<ScribeResult, Error>?

    func install(_ continuation: CheckedContinuation<ScribeResult, Error>) {
        let completed = lock.withLock { () -> Result<ScribeResult, Error>? in
            if let terminalResult { return terminalResult }
            self.continuation = continuation
            return nil
        }
        if let completed {
            continuation.resume(with: completed)
        }
    }

    func installTasks(provider: Task<Void, Never>, timeout: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            providerTask = provider
            timeoutTask = timeout
            return isResolved
        }
        if shouldCancel {
            provider.cancel()
            timeout.cancel()
        }
    }

    func resolve(_ result: Result<ScribeResult, Error>) {
        let state = lock.withLock { () -> (
            CheckedContinuation<ScribeResult, Error>?,
            Task<Void, Never>?,
            Task<Void, Never>?
        ) in
            guard !isResolved else { return (nil, nil, nil) }
            isResolved = true
            terminalResult = result
            let state = (continuation, providerTask, timeoutTask)
            continuation = nil
            return state
        }
        guard let continuation = state.0 else { return }
        state.1?.cancel()
        state.2?.cancel()
        continuation.resume(with: result)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}

enum ScribeCoordinatorError: Error, Equatable, Sendable {
    case invalidState
    case insertionAlreadyCompleted
}

enum ScribeSessionFailure: Equatable, Sendable {
    case provider(ScribeProviderError)
    case context(ScribeContextError)
    case voiceSessionBusy(VoiceSessionKind)
    case transcriptionEmpty
    case transcription
    case literalRepair
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
    private(set) var providerFailure: ScribeProviderFailure?
    private(set) var activeRequestID: UUID?
    private(set) var resolvedEnvironment: ResolvedWritingEnvironment?
    private(set) var exactLiterals: [ScribeExactLiteral] = []
    var canRetryGeneration: Bool { activeRequest != nil }

    private let audioCaptureService: AudioCaptureServing
    private let transcriptionEngine: TranscriptionEngine
    private let providerActionResolver: () throws -> ScribeProviderActionSnapshot
    private let contextService: ScribeContextServing
    private let sessionArbiter: VoiceSessionArbiter
    private let personalizationStore: PersonalizationStore
    private let generationTimeout: Duration
    private let generationSoftWait: Duration
    private let environmentRecognizer: WritingEnvironmentRecognizer
    private let writingEnvironmentPreferences: () -> WritingEnvironmentPreferenceLoadResult
    private let adaptationEnabled: () -> Bool
    private let providerDispatchAuthorization: @MainActor () -> Bool
    private var localTextConfiguration: TranscriptionConfiguration

    private var activeIntent: ScribeIntent?
    private var activeCapture: ScribeContextSnapshot?
    private var activeRequest: ScribeRequest?
    private var activeProviderRequest: ScribeProviderRequest?
    private var activeProviderAction: ScribeProviderActionSnapshot?
    private var voiceLease: VoiceSessionLease?
    private var generationTask: Task<Void, Never>?
    private var softWaitTask: Task<Void, Never>?
    private var generation = 0
    private(set) var activeAttemptID: UUID?
    private var insertionCompleted = false
    private var audioContinuation: AsyncStream<ScribeCapturedAudio>.Continuation?
    private var audioIngestionTask: Task<Void, Never>?
    private var isStarting = false

    init(
        audioCaptureService: AudioCaptureServing,
        transcriptionEngine: TranscriptionEngine,
        provider: any ScribeProvider,
        providerResolver: (() throws -> any ScribeProvider)? = nil,
        providerActionResolver: (() throws -> ScribeProviderActionSnapshot)? = nil,
        contextService: ScribeContextServing,
        sessionArbiter: VoiceSessionArbiter,
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        environmentRecognizer: WritingEnvironmentRecognizer = WritingEnvironmentRecognizer(),
        writingEnvironmentPreferences: @escaping () -> WritingEnvironmentPreferenceLoadResult = { .absent },
        adaptationEnabled: @escaping () -> Bool = { true },
        providerDispatchAuthorization: @escaping @MainActor () -> Bool = { true },
        transcriptionConfiguration: TranscriptionConfiguration = TranscriptionConfiguration(),
        generationTimeout: Duration = .seconds(30),
        generationSoftWait: Duration = .seconds(8)
    ) {
        self.audioCaptureService = audioCaptureService
        self.transcriptionEngine = transcriptionEngine
        if let providerActionResolver {
            self.providerActionResolver = providerActionResolver
        } else {
            let resolvedProvider = providerResolver ?? { provider }
            self.providerActionResolver = {
                ScribeProviderActionSnapshot(
                    provider: try resolvedProvider(),
                    destination: .legacyLocal
                )
            }
        }
        self.contextService = contextService
        self.sessionArbiter = sessionArbiter
        self.personalizationStore = personalizationStore
        self.environmentRecognizer = environmentRecognizer
        self.writingEnvironmentPreferences = writingEnvironmentPreferences
        self.adaptationEnabled = adaptationEnabled
        self.providerDispatchAuthorization = providerDispatchAuthorization
        self.localTextConfiguration = transcriptionConfiguration
        self.generationTimeout = generationTimeout
        self.generationSoftWait = generationSoftWait
    }

    var selectedTextDisclosure: String {
        activeProviderAction?.selectedTextDisclosure
            ?? "Selected text is used only after you choose Respond or Edit."
    }

    var activeProviderKind: ScribeProviderKind? {
        activeProviderAction?.destination.providerKind
    }

    func prepareTarget() throws {
        guard state == .idle || isTerminalState else {
            throw ScribeCoordinatorError.invalidState
        }
        resetTransientState()
        generation += 1
        do {
            let action = try providerActionResolver()
            try action.validateForAcquisition(intent: .compose)
            activeProviderAction = action
            try contextService.prepareTarget()
            state = .choosingIntent
        } catch let error as ScribeContextError {
            activeProviderAction = nil
            failure = .context(error)
            state = .failed(requestID: nil, error: .unavailable)
            throw error
        } catch {
            activeProviderAction = nil
            throw error
        }
    }

    func updateLocalTextConfiguration(_ configuration: TranscriptionConfiguration) {
        localTextConfiguration = configuration
    }

    func invalidateProviderWork() {
        generation += 1
        generationTask?.cancel()
        softWaitTask?.cancel()
        generationTask = nil
        softWaitTask = nil
        activeProviderRequest = nil
        activeProviderAction = nil
        activeAttemptID = nil
    }

    func begin(intent: ScribeIntent) async throws {
        guard !isStarting,
              state == .choosingIntent || state == .idle || isTerminalState else {
            throw ScribeCoordinatorError.invalidState
        }

        isStarting = true
        defer { isStarting = false }
        if state != .choosingIntent {
            resetTransientState()
        }
        generation += 1
        let beginGeneration = generation
        let requestID = UUID()
        activeRequestID = requestID
        activeIntent = intent

        let providerAction = try activeProviderAction ?? providerActionResolver()
        try providerAction.validateForAcquisition(intent: intent)
        activeProviderAction = providerAction

        do {
            voiceLease = try sessionArbiter.acquire(for: .scribe)
        } catch let error as VoiceSessionArbiterError {
            if case let .busy(kind) = error {
                failure = .voiceSessionBusy(kind)
            }
            throw error
        }

        do {
            let capture = try contextService.capture(for: intent)
            activeCapture = capture
            let recognizedEnvironmentID = environmentRecognizer.recognize(
                target: capture.target,
                signature: capture.recognitionSignature
            )
            resolvedEnvironment = WritingEnvironmentResolver.resolve(
                recognizedEnvironmentID: recognizedEnvironmentID,
                adaptationEnabled: adaptationEnabled(),
                preferenceLoadResult: writingEnvironmentPreferences()
            )
            try await transcriptionEngine.startSession()
            guard beginGeneration == generation else { throw CancellationError() }
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
            if let error = error as? ScribeContextError {
                failure = .context(error)
                state = .failed(requestID: requestID, error: .unavailable)
            } else if let error = error as? ScribeProviderFailure {
                setProviderFailure(error, requestID: requestID)
            }
            throw error
        }
    }

    func finishRecording() async {
        guard case .listening = state,
              let intent = activeIntent,
              let capture = activeCapture,
              let requestID = activeRequestID else { return }

        let runGeneration = generation
        state = .transcribing(requestID: requestID)
        let metrics = audioCaptureService.stopCapture()
        await finishAudioIngestion(cancel: false)
        guard runGeneration == generation else { return }

        do {
            let transcript = try await transcriptionEngine.finishSession(metrics: metrics)
                .cleanedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            guard !transcript.isEmpty else {
                failure = .transcriptionEmpty
                state = .failed(requestID: requestID, error: .emptyResult)
                return
            }

            literalTranscript = transcript
            let personalization = personalizationStore.load()
            let vocabularyProcessed = VocabularyPostProcessor.apply(
                to: transcript,
                configuration: localTextConfiguration
            )
            let environment = resolvedEnvironment ?? WritingEnvironmentResolver.resolve(
                recognizedEnvironmentID: .global,
                adaptationEnabled: true,
                preferenceLoadResult: .absent
            )
            let normalized = ScribeLiteralNormalizer.normalize(
                vocabularyProcessed,
                environmentID: environment.environmentID
            )
            guard normalized.parseStatus == .clean else {
                failure = .literalRepair
                state = .failed(requestID: requestID, error: .invalidResult)
                return
            }
            exactLiterals = normalized.exactLiterals
            let expandedTranscript = ShortcutExpansionService.expand(
                normalized.text,
                bundleIdentifier: capture.target.bundleIdentifier,
                shortcuts: personalization.shortcuts,
                protectedValues: normalized.exactLiterals.map(\.value)
            )
            guard try contextService.verifyTarget(for: capture) else {
                throw ScribeContextError.targetChanged
            }
            guard let providerAction = activeProviderAction else {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: .reconnect
                )
            }
            let context: ScribeRequestContext?
            if capture.scope == .selectedText {
                context = ScribeRequestContext(
                    artifact: .explicitSelection(ScribeExplicitSelectionArtifact(
                        captureID: capture.id,
                        target: capture.target,
                        verificationToken: capture.verificationToken,
                        text: capture.selectedText
                    )),
                    authorization: providerAction.contextAuthorization(for: capture)
                )
            } else {
                context = nil
            }
            let request = ScribeRequest(
                id: requestID,
                intent: intent,
                spokenTranscript: expandedTranscript,
                context: context,
                style: nil,
                resolvedEnvironment: environment,
                exactLiterals: normalized.exactLiterals
            )
            let providerRequest = ScribeProviderRequest(
                id: request.id,
                input: try ScribeRequestPolicy.providerSafeInput(
                    for: request,
                    destination: providerAction.destination
                )
            )
            activeRequest = request
            activeProviderRequest = providerRequest
            await startGeneration(
                request,
                providerRequest: providerRequest,
                providerAction: providerAction,
                generation: runGeneration
            )
        } catch let error as ScribeContextError {
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            failure = .context(error)
            state = .failed(requestID: requestID, error: .unavailable)
        } catch let error as ScribeProviderFailure {
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            setProviderFailure(error, requestID: requestID)
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
        guard let request = activeRequest,
              let providerRequest = activeProviderRequest,
              let providerAction = activeProviderAction else { return }
        generation += 1
        let retryGeneration = generation
        let previousTask = generationTask
        previousTask?.cancel()
        await previousTask?.value
        guard generation == retryGeneration else { return }
        do {
            if let activeCapture {
                guard try contextService.verifyTarget(for: activeCapture) else {
                    throw ScribeContextError.targetChanged
                }
            }
            try ScribeRequestPolicy.validateEgress(
                request,
                destination: providerAction.destination
            )
        } catch let error as ScribeContextError {
            failure = .context(error)
            state = .failed(requestID: request.id, error: .unavailable)
            return
        } catch {
            setProviderFailure(.invalidResult, requestID: request.id)
            return
        }
        await startGeneration(
            request,
            providerRequest: providerRequest,
            providerAction: providerAction,
            generation: retryGeneration
        )
    }

    func useLiteralTranscript() {
        guard let requestID = activeRequestID,
              let literalTranscript,
              !literalTranscript.isEmpty else { return }
        let result = ScribeResult(requestID: requestID, text: literalTranscript)
        reviewedResult = result
        failure = nil
        providerFailure = nil
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

        state = .inserting(requestID: result.requestID)
        do {
            guard try contextService.insert(result.text, for: capture) else {
                throw ScribeContextError.unsupportedSelection
            }
            insertionCompleted = true
            clearContext()
            clearContent()
            state = .succeeded(requestID: result.requestID)
        } catch let error as ScribeContextError {
            failure = .context(error)
            state = .insertionRecovery(result)
            throw error
        }
    }

    func takeReviewedDraftForCopy() -> String? {
        guard let result = reviewedResult else { return nil }
        let text = result.text
        clearContext()
        clearContent()
        state = .succeeded(requestID: result.requestID)
        return text
    }

    func cancel() async {
        let cancelledRequestID = activeRequestID
        generation += 1
        generationTask?.cancel()
        generationTask = nil
        softWaitTask?.cancel()
        softWaitTask = nil

        if case .listening = state {
            _ = audioCaptureService.stopCapture()
        }
        await finishAudioIngestion(cancel: true)
        await transcriptionEngine.cancelSession()
        releaseVoiceLease()
        if activeCapture == nil {
            contextService.discardPreparedTarget()
        }
        clearContext()
        clearContent()
        state = .cancelled(requestID: cancelledRequestID)
    }

    private func startGeneration(
        _ request: ScribeRequest,
        providerRequest: ScribeProviderRequest,
        providerAction: ScribeProviderActionSnapshot,
        generation expectedGeneration: Int
    ) async {
        guard providerDispatchAuthorization() else {
            await cancel()
            return
        }
        state = .generating(requestID: request.id)
        failure = nil
        providerFailure = nil
        let attemptID = UUID()
        activeAttemptID = attemptID
        softWaitTask?.cancel()
        softWaitTask = Task { @MainActor [weak self, generationSoftWait] in
            do {
                try await Task.sleep(for: generationSoftWait)
            } catch {
                return
            }
            guard let self,
                  self.generation == expectedGeneration,
                  self.activeAttemptID == attemptID,
                  case .generating = self.state else { return }
            self.state = .generatingSlow(requestID: request.id)
        }

        let task = Task { [provider = providerAction.provider, generationTimeout] in
            do {
                let result = try await Self.generate(
                    providerRequest,
                    provider: provider,
                    timeout: generationTimeout
                )
                guard !Task.isCancelled else { return }
                guard result.requestID == request.id else {
                    throw ScribeProviderError.invalidResult
                }
                let validatedText = try ScribeRequestPolicy.validateOutput(
                    result.text,
                    requiredLiterals: request.exactLiterals,
                    spokenRequest: request.spokenTranscript
                )
                let validatedResult = ScribeResult(requestID: request.id, text: validatedText)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID else { return }
                    self.reviewedResult = validatedResult
                    self.failure = nil
                    self.providerFailure = nil
                    self.state = .reviewing(validatedResult)
                }
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                let failure = ScribeProviderFailure(
                    phase: .generation,
                    category: .transportUnavailable,
                    retryDisposition: .manualNow
                )
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID else { return }
                    self.setProviderFailure(failure, requestID: request.id)
                }
            } catch let error as ScribeProviderFailure {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID else { return }
                    self.setProviderFailure(error, requestID: request.id)
                }
            } catch let error as ScribeProviderError {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID else { return }
                    self.setProviderFailure(error, requestID: request.id)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID else { return }
                    self.setProviderFailure(.unavailable, requestID: request.id)
                }
            }
        }
        generationTask = task
        await task.value
        softWaitTask?.cancel()
        softWaitTask = nil
        if generation == expectedGeneration {
            generationTask = nil
        }
    }

    private nonisolated static func generate(
        _ request: ScribeProviderRequest,
        provider: any ScribeProvider,
        timeout: Duration
    ) async throws -> ScribeResult {
        let race = ScribeGenerationRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let providerTask = Task {
                    do {
                        race.resolve(.success(try await provider.generate(request)))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    race.resolve(.failure(ScribeProviderError.timedOut))
                }
                race.installTasks(provider: providerTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.cancel()
        }
    }

    private func setProviderFailure(_ error: ScribeProviderError, requestID: UUID) {
        providerFailure = nil
        failure = .provider(error)
        state = .failed(requestID: requestID, error: error)
    }

    private func setProviderFailure(_ error: ScribeProviderFailure, requestID: UUID) {
        providerFailure = error
        let legacyError: ScribeProviderError
        switch error.category {
        case .transportUnavailable:
            legacyError = .offline
        case .timedOut:
            legacyError = .timedOut
        case .cancelled:
            legacyError = .cancelled
        case .invalidResponse:
            legacyError = .invalidResult
        default:
            legacyError = .unavailable
        }
        failure = .provider(legacyError)
        state = .failed(requestID: requestID, error: legacyError)
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
        softWaitTask?.cancel()
        softWaitTask = nil
        clearContext()
        clearContent()
        insertionCompleted = false
    }

    private func clearContent() {
        activeIntent = nil
        activeRequest = nil
        activeProviderRequest = nil
        activeProviderAction = nil
        activeAttemptID = nil
        activeRequestID = nil
        literalTranscript = nil
        reviewedResult = nil
        failure = nil
        providerFailure = nil
        resolvedEnvironment = nil
        exactLiterals = []
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
