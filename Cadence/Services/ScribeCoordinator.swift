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
    case missingSource
    case capability(ScribeProviderCapabilityRejection)
    case recipientRestriction
    case refinementUnchanged
    case selectedTextUnchanged
    case memoryUnavailable
    case memoryAmbiguous
    case persistentMemoryUnavailable
}

@MainActor
final class ScribeCoordinator {
    var onStateChange: ((ScribeSessionState) -> Void)?
    var onAudioLevel: ((Double) -> Void)?

    private(set) var state = ScribeSessionState.idle {
        didSet {
            onStateChange?(state)
            finishPerformanceIfTerminal(state)
        }
    }
    private(set) var literalTranscript: String?
    private(set) var reviewedResult: ScribeResult?
    private(set) var failure: ScribeSessionFailure?
    private(set) var providerFailure: ScribeProviderFailure?
    private(set) var activeRequestID: UUID?
    private(set) var resolvedEnvironment: ResolvedWritingEnvironment?
    private(set) var resolvedGuidance: ResolvedScribeGuidance?
    private(set) var exactLiterals: [ScribeExactLiteral] = []
    var canRetryGeneration: Bool {
        guard activeRequest != nil, !isRefining, lastRefinementInstruction == nil,
              !isSelectedTextSourceExcluded, !insertionOutcomeUncertain else { return false }
        switch failure {
        case .provider(let error) where !error.permitsUnchangedRetry:
            return false
        case .missingSource, .memoryAmbiguous, .capability(.inputTooLarge), .capability(.unsupportedModality), .capability(.unsupportedTask):
            return false
        default:
            return true
        }
    }
    var targetDisplayName: String? { activeCapture?.applicationTarget.displayName }
    var usesSelectedTextContext: Bool { activeSelectedTextSnapshot != nil }
    var sessionMemoryReviewStatus: String? {
        sessionFactsReviewSource?.status
    }
    var sessionFactsReviewSource: ScribeSessionFactsReviewSource? {
        guard let reviewedResult else { return nil }
        let session = activeMemoryDraftFacts
        let saved = activePersistentDraftFacts
        let texts = (session?.texts ?? []) + (saved?.texts ?? [])
        guard !texts.isEmpty else { return nil }
        let kind: ScribeSessionFactsReviewSource.Kind
        if session != nil, saved != nil { kind = .mixed }
        else if saved != nil { kind = .saved }
        else { kind = .session }
        return .init(
            id: reviewedResult.requestID, facts: texts,
            recordIDs: (session?.recordIDs ?? []) + (saved?.recordIDs ?? []),
            kind: kind
        )
    }
    var selectedTextSourceProvenance: ComposeGroundedSourceProvenance? { activeSelectedTextCompilation?.provenance }
    private(set) var isSelectedTextSourceExcluded = false
    private var isSelectedTextRewriteAction = false
    private var isRefreshingSelectedSource = false
    var selectedTextReviewSource: ScribeSelectedTextReviewSource? {
        guard reviewedResult != nil, let snapshot = activeSelectedTextSnapshot,
              let provenance = activeSelectedTextCompilation?.provenance,
              provenance.sourceSnapshotID == snapshot.id else { return nil }
        return .init(id: snapshot.id, text: snapshot.selectedText,
                     includedUTF8Bytes: provenance.includedUTF8Bytes, isExcluded: isSelectedTextSourceExcluded,
                     isUnchanged: failure == .selectedTextUnchanged)
    }
    /// In a contextual rewrite the recording is an instruction, not an
    /// alternative draft. Never promote it into replacement text on failure.
    var literalRecoveryTranscript: String? {
        isSelectedTextRewriteAction || isPersistentMemoryCommandAction ? nil : literalTranscript
    }
    var selectedTextContextStatus: String? {
        selectedTextReviewSource?.status ?? (usesSelectedTextContext ? "Selected text · This Mac" : nil)
    }

    func excludeSelectedTextSource(id: UUID) {
        guard permitsSelectedSourceManagement, let result = reviewedResult, activeSelectedTextSnapshot?.id == id,
              !isSelectedTextSourceExcluded, ensureSelectedTextAuthorization() else { return }
        cancelOutstandingGeneration()
        isSelectedTextSourceExcluded = true
        // Keep old source attribution and its draft visible. Exclusion is not
        // permission revocation; the latter still clears every derivative.
        state = .reviewing(result)
    }

    func canInspectSelectedTextSource(id: UUID) -> Bool {
        guard permitsSelectedSourceManagement, reviewedResult != nil, activeSelectedTextSnapshot?.id == id else { return false }
        return ensureSelectedTextAuthorization()
    }

    private var permitsSelectedSourceManagement: Bool {
        switch state {
        case .reviewing, .insertionRecovery, .generating, .generatingSlow: return true
        default: return false
        }
    }
    var isRefining: Bool { refinementAction != nil }
    var canRefineReviewedDraft: Bool {
        guard isReviewingDraft, !isStarting, !isRefining,
              !insertionOutcomeUncertain,
              reviewedResult != nil, activeRequest != nil, draftRevisionSession != nil,
              activeProviderAction?.destination == .legacyLocal,
              activeSelectedTextSnapshot == nil,
              activeMemoryDraftFacts == nil,
              activePersistentDraftFacts == nil else { return false }
        return true
    }
    var canUndoRefinement: Bool {
        isReviewingDraft && !isRefining && !insertionOutcomeUncertain
            && (draftRevisionSession?.currentVersionIndex ?? 0) > 0
    }
    var refinementUnavailableReason: String? {
        if usesSelectedTextContext { return "To revise selected text again, select it and start a new Compose request." }
        if activeMemoryDraftFacts != nil {
            return "To revise a draft that used session facts, start a new Compose request."
        }
        if activePersistentDraftFacts != nil {
            return "To revise a draft that used saved facts, start a new Compose request."
        }
        return activeProviderAction?.destination == .legacyLocal ? nil : ScribeDraftRefinementPolicy.localOnlyMessage
    }
    private(set) var lastRefinementInstruction: String?
    private(set) var draftRevisionSession: ScribeDraftRevisionSession?

    private struct RefinementAction {
        let id: UUID
        let session: ScribeDraftRevisionSession
        let providerAction: ScribeProviderActionSnapshot
        var token: ScribeDraftRevisionToken?
    }
    private var refinementAction: RefinementAction?
    private var draftRevisionStore = ScribeDraftRevisionStore()
    private var revisionLiterals: [UUID: [ScribeExactLiteral]] = [:]

    private var isReviewingDraft: Bool {
        switch state {
        case .reviewing, .insertionRecovery: return true
        default: return false
        }
    }

    private let audioCaptureService: AudioCaptureServing
    private let transcriptionEngine: TranscriptionEngine
    private let providerActionResolver: @MainActor () async throws -> ScribeProviderActionSnapshot
    private let contextService: ScribeContextServing
    private let selectedTextContext: (any ComposeSelectedTextContextServing)?
    private var sessionMemoryContext: (any ComposeSessionMemoryContextServing)?
    private var persistentMemoryContext: (any ComposePersistentMemoryContextServing)?
    private let sessionArbiter: VoiceSessionArbiter
    private let personalizationStore: PersonalizationStore
    private let generationTimeout: Duration
    private let generationSoftWait: Duration
    private let noSpeechFeedbackDuration: Duration
    private let environmentRecognizer: WritingEnvironmentRecognizer
    private let applicationGuidanceResolver: @MainActor (
        ApplicationTargetCapture,
        TargetRecognitionSignature?
    ) -> ResolvedScribeGuidance?
    private let writingEnvironmentPreferences: () -> WritingEnvironmentPreferenceLoadResult
    private let adaptationEnabled: () -> Bool
    private let globalWritingDefaults: () -> ComposeGlobalWritingDefaults
    private let applicationWritingDefaults: @MainActor (ApplicationTargetCapture) -> [ComposeWritingPreferenceValue]
    private var activeWritingDefaults: [ComposeWritingPreferenceValue] = []
    private let providerDispatchAuthorization: @MainActor (ScribeProviderActionSnapshot) async -> Bool
    /// Optional diagnostics only. Retries do not extend a finished sample.
    /// Total duration through insertion includes speaking and review dwell;
    /// only suitable stage intervals can measure application overhead.
    private let performanceRecorder: ScribePerformanceRecorder?
    private var localTextConfiguration: TranscriptionConfiguration

    private var activeCapture: ScribeContextSnapshot?
    private var activeSelectedTextSnapshot: ComposeContextSnapshot?
    private var activeSelectedTextCompilation: ComposeGroundedCompilation?
    private var activeRequest: ScribeRequest?
    private var activeProviderRequest: ScribeProviderRequest?
    private var activeProviderAction: ScribeProviderActionSnapshot?
    private var activeMemoryDraftFacts: ComposeSessionMemoryDraftFacts?
    private var activePersistentDraftFacts: ComposeSessionMemoryDraftFacts?
    private var activePersistentMemoryProposal: ScribePersistentMemorySaveProposal?
    private var activePersistentForgetProposal: ScribePersistentMemoryForgetProposal?
    private var isPersistentMemoryCommandAction = false
    private var memoryDraftSnapshotResolved = false
    private var persistentDraftSnapshotResolved = false
    private var memoryExcludedActionID: UUID?
    private var memoryExclusionBaseline: ComposeSessionMemoryDraftFacts?
    private var persistentExclusionBaseline: ComposeSessionMemoryDraftFacts?
    private var memoryExcludedRecordIDs: Set<UUID> = []
    private var voiceLease: VoiceSessionLease?
    private var generationTask: Task<Void, Never>?
    private var softWaitTask: Task<Void, Never>?
    private var generation = 0
    /// Monotonic local revisions make an action and each provider attempt
    /// unambiguous even when a transport returns an old request ID.
    private var actionRevision = 0
    private var attemptRevision = 0
    private(set) var activeAttemptID: UUID?
    private var insertionCompleted = false
    private var insertionAttemptID: UUID?
    private(set) var insertionOutcomeUncertain = false
    private var audioContinuation: AsyncStream<ScribeCapturedAudio>.Continuation?
    private var audioIngestionTask: Task<Void, Never>?
    private var isStarting = false
    var onTargetPin: ((ApplicationTargetCapture, String?) -> Void)?
    var onTargetClear: ((UUID) -> Void)?

    init(
        audioCaptureService: AudioCaptureServing,
        transcriptionEngine: TranscriptionEngine,
        provider: any ScribeProvider,
        providerResolver: (() throws -> any ScribeProvider)? = nil,
        providerActionResolver: (@MainActor () async throws -> ScribeProviderActionSnapshot)? = nil,
        contextService: ScribeContextServing,
        sessionArbiter: VoiceSessionArbiter,
        selectedTextContext: (any ComposeSelectedTextContextServing)? = nil,
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        environmentRecognizer: WritingEnvironmentRecognizer = WritingEnvironmentRecognizer(),
        applicationGuidanceResolver: @escaping @MainActor (
            ApplicationTargetCapture,
            TargetRecognitionSignature?
        ) -> ResolvedScribeGuidance? = { _, _ in nil },
        writingEnvironmentPreferences: @escaping () -> WritingEnvironmentPreferenceLoadResult = { .absent },
        globalWritingDefaults: @escaping () -> ComposeGlobalWritingDefaults = { .init() },
        applicationWritingDefaults: @escaping @MainActor (ApplicationTargetCapture) -> [ComposeWritingPreferenceValue] = { _ in [] },
        adaptationEnabled: @escaping () -> Bool = { true },
        providerDispatchAuthorization: @escaping @MainActor (ScribeProviderActionSnapshot) async -> Bool = { _ in true },
        performanceRecorder: ScribePerformanceRecorder? = nil,
        transcriptionConfiguration: TranscriptionConfiguration = TranscriptionConfiguration(),
        generationTimeout: Duration = .seconds(30),
        generationSoftWait: Duration = .seconds(8),
        noSpeechFeedbackDuration: Duration = .milliseconds(1500)
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
        self.selectedTextContext = selectedTextContext
        self.sessionArbiter = sessionArbiter
        self.personalizationStore = personalizationStore
        self.environmentRecognizer = environmentRecognizer
        self.applicationGuidanceResolver = applicationGuidanceResolver
        self.writingEnvironmentPreferences = writingEnvironmentPreferences
        self.adaptationEnabled = adaptationEnabled
        self.globalWritingDefaults = globalWritingDefaults
        self.applicationWritingDefaults = applicationWritingDefaults
        self.providerDispatchAuthorization = providerDispatchAuthorization
        self.performanceRecorder = performanceRecorder
        self.localTextConfiguration = transcriptionConfiguration
        self.generationTimeout = generationTimeout
        self.generationSoftWait = generationSoftWait
        self.noSpeechFeedbackDuration = noSpeechFeedbackDuration
        selectedTextContext?.onAccessRevoked = { [weak self] actionID in
            self?.selectedTextAccessRevoked(actionID: actionID)
        }
    }

    var activeProviderKind: ScribeProviderKind? {
        activeProviderAction?.destination.providerKind
    }

    var activeProviderActionIdentity: ScribeProviderActionIdentity? {
        activeProviderAction?.actionIdentity
    }

    /// Installed after AppModel constructs this coordinator, so memory can
    /// validate against its live action ID without an initialization cycle.
    func installSessionMemoryContext(_ context: (any ComposeSessionMemoryContextServing)?) {
        sessionMemoryContext?.clear(actionID: nil)
        sessionMemoryContext = context
    }

    func installPersistentMemoryContext(_ context: (any ComposePersistentMemoryContextServing)?) {
        persistentMemoryContext?.clear(actionID: nil)
        persistentMemoryContext = context
    }

    func prepareTarget() async throws {
        guard state == .idle || isTerminalState else {
            throw ScribeCoordinatorError.invalidState
        }
        resetTransientState()
        generation += 1
        do {
            try await contextService.prepareTarget()
            state = .idle
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

    /// Starts the only supported Scribe acquisition flow: target-pinned direct
    /// dictation. Optional selected-text capture has a separate local-only gate.
    func beginDirectDictation(captureSelectedText: Bool = true, actionID: UUID = UUID()) async throws {
        guard !isStarting else { throw ScribeCoordinatorError.invalidState }
        let requestID = actionID
        performanceRecorder?.begin(actionID: requestID)
        do {
            try await prepareTarget()
            try await beginDirectDictationAfterPreparation(requestID: requestID, captureSelectedText: captureSelectedText)
        } catch {
            performanceRecorder?.finish(actionID: requestID, outcome: .failed)
            throw error
        }
    }

    func updateLocalTextConfiguration(_ configuration: TranscriptionConfiguration) {
        localTextConfiguration = configuration
    }

    func invalidateProviderWork() {
        if let actionID = activeRequestID { selectedTextAccessRevoked(actionID: actionID) }
        selectedTextContext?.clear(actionID: nil)
        sessionMemoryContext?.clear(actionID: activeRequestID)
        persistentMemoryContext?.clear(actionID: activeRequestID)
        generation += 1
        actionRevision &+= 1
        generationTask?.cancel()
        softWaitTask?.cancel()
        generationTask = nil
        softWaitTask = nil
        activeProviderRequest = nil
        activeProviderAction = nil
        activeAttemptID = nil
    }

    private func beginDirectDictationAfterPreparation(requestID: UUID, captureSelectedText: Bool) async throws {
        guard !isStarting,
              state == .idle || isTerminalState else {
            throw ScribeCoordinatorError.invalidState
        }

        isStarting = true
        defer { isStarting = false }
        resetTransientState()
        generation += 1
        actionRevision &+= 1
        let beginGeneration = generation
        activeRequestID = requestID
        activeWritingDefaults = globalWritingDefaults().values

        let providerAction: ScribeProviderActionSnapshot
        if let activeProviderAction {
            providerAction = activeProviderAction
        } else {
            providerAction = try await providerActionResolver()
        }
        try providerAction.validateForAcquisition()
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
            let capture = try contextService.capture()
            activeCapture = capture
            let applicationTarget = capture.applicationTarget
            onTargetPin?(applicationTarget, applicationTarget.displayName)
            performanceRecorder?.mark(.targetPinned, actionID: requestID)
            let recognizedEnvironmentID = environmentRecognizer.recognize(
                target: capture.target,
                signature: capture.recognitionSignature
            )
            resolvedEnvironment = WritingEnvironmentResolver.resolve(
                recognizedEnvironmentID: recognizedEnvironmentID,
                adaptationEnabled: adaptationEnabled(),
                preferenceLoadResult: writingEnvironmentPreferences()
            )
            resolvedGuidance = applicationGuidanceResolver(
                applicationTarget,
                capture.recognitionSignature
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
                    self.performanceRecorder?.mark(.firstAudioFrame, actionID: requestID)
                    await transcriptionEngine.appendAudio(capturedAudio.chunk)
                    self.onAudioLevel?(capturedAudio.level)
                }
            }
            try audioCaptureService.startCapture { [continuation] chunk, level in
                continuation.yield(ScribeCapturedAudio(chunk: chunk, level: level))
            }
            state = .listening(requestID: requestID)
            performanceRecorder?.mark(.listening, actionID: requestID)
            // Style lookup happens after audio is live and is frozen for this
            // recording. A verified app choice overrides only its own fields.
            let appChoices = applicationWritingDefaults(applicationTarget)
            activeWritingDefaults = ComposePreferenceResolver.combining(
                global: activeWritingDefaults, application: appChoices
            )
            // Optional content starts only after the microphone is running.
            // The controller reads the pinned invocation, never a new target.
            if captureSelectedText {
                selectedTextContext?.beginCapture(actionID: requestID, capture: capture, destination: providerAction.destination)
            }
            // Identity metadata may require AX round trips. Schedule it after
            // the microphone is live so it cannot lengthen shortcut pickup.
            Task { [weak self] in
                guard let self, self.activeRequestID == requestID,
                      self.activeCapture == capture else { return }
                self.sessionMemoryContext?.begin(
                    actionID: requestID, capture: capture, destination: providerAction.destination
                )
            }
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
        if isRefining {
            await finishRefinementRecording()
            return
        }
        guard case .listening = state,
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
            performanceRecorder?.mark(.transcriptionFinished, actionID: requestID)
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            guard !transcript.isEmpty else {
                await finishEmptyRecording(requestID: requestID, expectedGeneration: runGeneration)
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
            if let command = ComposePersistentMemoryCommand.parse(normalized.text) {
                isPersistentMemoryCommandAction = true
                do {
                    guard let memory = persistentMemoryContext,
                          memory.acceptsExplicitSaves,
                          memory.begin(actionID: requestID, capture: capture) else {
                        throw ComposePersistentMemoryRuntimeError.unavailable
                    }
                    switch command {
                    case let .remember(fact):
                        let proposal = try memory.prepareSaveExplicitFact(
                            fact, actionID: requestID, capture: capture
                        )
                        activePersistentMemoryProposal = proposal
                        state = .persistentMemoryProposal(.init(
                            requestID: requestID, proposalID: proposal.token.id,
                            fact: proposal.record.text
                        ))
                    case let .correct(oldFact, newFact):
                        let correction = try memory.prepareCorrection(
                            oldFact: oldFact, newFact: newFact,
                            actionID: requestID, capture: capture
                        )
                        activePersistentMemoryProposal = correction.proposal
                        state = .persistentMemoryProposal(.init(
                            requestID: requestID,
                            proposalID: correction.proposal.token.id,
                            fact: correction.proposal.record.text,
                            replacingFact: correction.previous.text
                        ))
                    case .inspectCurrentDocument:
                        let facts = try memory.inspect(actionID: requestID, capture: capture)
                        let detail = facts.isEmpty
                            ? "Nothing is saved for this document."
                            : facts.map { "• \($0.text)" }.joined(separator: "\n\n")
                        let notice = ComposeSessionMemoryNotice(
                            requestID: requestID,
                            title: "Saved facts for this document", detail: detail
                        )
                        clearContext()
                        clearContent()
                        state = .memoryNotice(notice)
                    case .forgetCurrentDocument:
                        let proposal = try memory.prepareForgetCurrentDocument(
                            actionID: requestID, capture: capture
                        )
                        if proposal.activeFactCount == 0 {
                            clearContext()
                            clearContent()
                            state = .memoryNotice(.init(
                                requestID: requestID, title: "No saved facts",
                                detail: "Nothing is saved for this document."
                            ))
                        } else {
                            activePersistentForgetProposal = proposal
                            state = .persistentMemoryForgetProposal(.init(
                                requestID: requestID,
                                proposalID: proposal.token.id,
                                factCount: proposal.activeFactCount
                            ))
                        }
                    }
                } catch {
                    failPersistentMemoryAction(requestID: requestID)
                }
                return
            }
            if let memory = sessionMemoryContext,
               memory.acceptsExplicitCommands,
               activeProviderAction?.destination == .legacyLocal,
               let command = ComposeSessionMemoryCommand.parse(normalized.text) {
                do {
                    let notice = try memory.perform(
                        command, actionID: requestID, capture: capture, destination: .legacyLocal
                    )
                    clearContext()
                    clearContent()
                    state = .memoryNotice(notice)
                } catch {
                    clearContext()
                    clearContent()
                    failure = .memoryUnavailable
                    state = .failed(requestID: requestID, error: .unavailable)
                }
                return
            }
            let expandedTranscript = ShortcutExpansionService.expand(
                normalized.text,
                bundleIdentifier: capture.target.bundleIdentifier,
                shortcuts: personalization.shortcuts,
                protectedValues: normalized.exactLiterals.map(\.value)
            )
            let writing = ScribeWritingDirectionParser.parse(
                expandedTranscript,
                protectedValues: normalized.exactLiterals.map(\.value)
            )
            if !writing.unresolvedReferences.isEmpty {
                let selection: ComposeContextSnapshot?
                if ComposeSelectedTextRewritePolicy.canUseSelection(for: writing),
                   activeProviderAction?.destination == .legacyLocal {
                    selection = await selectedTextContext?.selectedText(for: requestID)
                } else { selection = nil }
                guard runGeneration == generation, activeRequestID == requestID else { return }
                guard let selection,
                      selection.target.action.actionID == requestID,
                      selection.target.source.captureID == capture.id,
                      selection.target.source.target == capture.target,
                      selectedTextContext?.authorizationIsCurrent(for: selection) == true else {
                    selectedTextContext?.clear(actionID: requestID)
                    failure = .missingSource
                    state = .failed(requestID: requestID, error: .invalidResult)
                    return
                }
                activeSelectedTextSnapshot = selection
                isSelectedTextRewriteAction = true
            } else {
                selectedTextContext?.clear(actionID: requestID)
            }
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
            let request = ScribeRequest(
                id: requestID,
                intent: .compose,
                spokenTranscript: expandedTranscript,
                context: nil,
                style: nil,
                resolvedEnvironment: environment,
                resolvedGuidance: resolvedGuidance,
                exactLiterals: normalized.exactLiterals,
                writingDefaults: activeWritingDefaults
            )
            activeRequest = request
            await startGeneration(
                request,
                providerAction: providerAction,
                generation: runGeneration
            )
        } catch WhisperEngineError.emptyAudio, WhisperEngineError.noTranscript {
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            await finishEmptyRecording(requestID: requestID, expectedGeneration: runGeneration)
        } catch let error as ScribeContextError {
            releaseVoiceLease()
            guard runGeneration == generation else { return }
            retainReviewedDraftOrFail(.context(error), requestID: requestID)
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
            retainReviewedDraftOrFail(.transcription, requestID: requestID)
            scribeLogger.error("Compose transcription failed category=transcription")
        }
    }

    /// The visible proposal is a local confirmation step, never a provider
    /// result. The encrypted store rechecks the exact action, document,
    /// consent, and revision before this call can commit anything.
    @discardableResult
    func confirmPersistentMemoryProposal(id: UUID) -> Bool {
        guard case let .persistentMemoryProposal(review) = state,
              review.proposalID == id,
              review.requestID == activeRequestID,
              let capture = activeCapture,
              let proposal = activePersistentMemoryProposal,
              proposal.token.id == id,
              proposal.record.text == review.fact,
              let memory = persistentMemoryContext else { return false }
        do {
            try memory.completeSave(
                proposal, decision: .confirmedByUser,
                actionID: review.requestID, capture: capture
            )
            let notice = ComposeSessionMemoryNotice(
                requestID: review.requestID,
                title: review.replacingFact == nil
                    ? "Saved for this document" : "Corrected for this document",
                detail: "Saved on this Mac for up to 30 days: \(review.fact)"
            )
            clearContext()
            clearContent()
            state = .memoryNotice(notice)
            return true
        } catch {
            failPersistentMemoryAction(requestID: review.requestID)
            return false
        }
    }

    @discardableResult
    func confirmPersistentMemoryForgetProposal(id: UUID) -> Bool {
        guard case let .persistentMemoryForgetProposal(review) = state,
              review.proposalID == id,
              review.requestID == activeRequestID,
              let capture = activeCapture,
              let proposal = activePersistentForgetProposal,
              proposal.token.id == id,
              let memory = persistentMemoryContext else { return false }
        do {
            try memory.confirmForgetCurrentDocument(
                proposal, actionID: review.requestID, capture: capture
            )
            let notice = ComposeSessionMemoryNotice(
                requestID: review.requestID,
                title: "Forgot saved facts for this document",
                detail: "The saved facts for this document were removed from Cadence."
            )
            clearContext()
            clearContent()
            state = .memoryNotice(notice)
            return true
        } catch {
            failPersistentMemoryAction(requestID: review.requestID)
            return false
        }
    }

    func persistentMemoryDidInvalidate() {
        if activePersistentDraftFacts != nil {
            invalidateMemoryBackedDraft(requestID: activeRequestID)
        } else if activePersistentMemoryProposal != nil || activePersistentForgetProposal != nil {
            guard let activeRequestID else { return }
            failPersistentMemoryAction(requestID: activeRequestID)
        }
    }

    private func failPersistentMemoryAction(requestID: UUID) {
        clearContext()
        clearContent()
        failure = .persistentMemoryUnavailable
        state = .failed(requestID: requestID, error: .unavailable)
    }

    private func finishEmptyRecording(requestID: UUID, expectedGeneration: Int) async {
        // A retained draft still needs explicit recovery; an empty recording does not.
        guard reviewedResult == nil, literalTranscript?.isEmpty != false else {
            retainReviewedDraftOrFail(.transcriptionEmpty, requestID: requestID)
            return
        }
        failure = .transcriptionEmpty
        state = .failed(requestID: requestID, error: .emptyResult)
        do { try await Task.sleep(for: noSpeechFeedbackDuration) } catch { return }
        guard generation == expectedGeneration, activeRequestID == requestID,
              failure == .transcriptionEmpty,
              state == .failed(requestID: requestID, error: .emptyResult) else { return }
        resetTransientState()
        state = .idle
    }

    func retryGeneration() async {
        // A failed revision must be recovered explicitly. Retrying the original
        // speech would silently replace the accepted version with an old draft.
        guard canRetryGeneration else { return }
        guard let request = activeRequest,
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
            retainReviewedDraftOrFail(.context(error), requestID: request.id)
            return
        } catch {
            setProviderFailure(.invalidResult, requestID: request.id)
            return
        }
        await startGeneration(
            request,
            providerAction: providerAction,
            generation: retryGeneration
        )
    }

    func useLiteralTranscript() {
        guard let requestID = activeRequestID,
              let literalTranscript = literalRecoveryTranscript,
              !literalTranscript.isEmpty,
              reviewedResult == nil else { return }
        let result = ScribeResult(requestID: requestID, text: literalTranscript)
        reviewedResult = result
        startDraftRevisionSession(result)
        failure = nil
        providerFailure = nil
        state = .reviewing(result)
    }

    /// Starts a new, independently pinned dictation action.  A retained draft
    /// must never be reused as input to a new recording.
    private var isReRecording = false

    func reRecord() async throws {
        guard !isReRecording else { return }
        isReRecording = true
        defer { isReRecording = false }
        // Capture the one-action choice before cancel clears the old state.
        // Exclusion must not be undone by the generic Record Again route.
        let captureSelectedText = !isSelectedTextSourceExcluded
        await cancel()
        try await beginDirectDictation(captureSelectedText: captureSelectedText)
    }

    /// The user explicitly discards the previous draft and supplies a complete
    /// new message. No prior source or draft becomes input to this recording.
    @discardableResult
    func recordReplacementWithoutSelectedSource(id: UUID) async throws -> Bool {
        guard !isReRecording, permitsSelectedSourceManagement, reviewedResult != nil,
              isSelectedTextSourceExcluded, activeSelectedTextSnapshot?.id == id else { return false }
        try await reRecord()
        return true
    }

    /// Discard the reviewed derivative and reuse only the user's editing
    /// instruction. Capture is refreshed in the original field, under fresh
    /// action/snapshot identities and current consent; no microphone is opened.
    @discardableResult
    func refreshSelectedTextSource(id: UUID) async -> Bool {
        guard !isRefreshingSelectedSource, !isReRecording, !isStarting,
              permitsSelectedSourceManagement, reviewedResult != nil,
              !isSelectedTextSourceExcluded, activeSelectedTextSnapshot?.id == id,
              ensureSelectedTextAuthorization(),
              let capture = activeCapture, let previousRequest = activeRequest,
              let providerAction = activeProviderAction, providerAction.destination == .legacyLocal,
              let selectedTextContext else { return false }
        isRefreshingSelectedSource = true
        defer { isRefreshingSelectedSource = false }
        let originalTranscript = literalTranscript
        cancelOutstandingGeneration()
        let expectedGeneration = generation
        actionRevision &+= 1
        performanceRecorder?.finish(actionID: previousRequest.id, outcome: .cancelled)
        clearContent()
        let requestID = UUID()
        activeRequestID = requestID
        isSelectedTextRewriteAction = true
        activeProviderAction = providerAction
        literalTranscript = originalTranscript
        resolvedEnvironment = previousRequest.resolvedEnvironment
        resolvedGuidance = previousRequest.resolvedGuidance
        exactLiterals = previousRequest.exactLiterals
        activeWritingDefaults = previousRequest.writingDefaults
        performanceRecorder?.begin(actionID: requestID)
        performanceRecorder?.mark(.targetPinned, actionID: requestID)
        state = .generating(requestID: requestID)
        do {
            try await contextService.restoreTargetForContextRefresh(capture)
            guard generation == expectedGeneration, activeRequestID == requestID else { return true }
            selectedTextContext.beginCapture(actionID: requestID, capture: capture, destination: providerAction.destination)
            let selection = await selectedTextContext.selectedText(for: requestID)
            guard generation == expectedGeneration, activeRequestID == requestID else { return true }
            guard let selection, selection.target.action.actionID == requestID,
                  selection.target.source.captureID == capture.id,
                  selection.target.source.target == capture.target,
                  selectedTextContext.authorizationIsCurrent(for: selection) else {
                selectedTextContext.clear(actionID: requestID)
                failure = .missingSource
                state = .failed(requestID: requestID, error: .invalidResult)
                return true
            }
            activeSelectedTextSnapshot = selection
            let request = ScribeRequest(id: requestID, intent: .compose,
                spokenTranscript: previousRequest.spokenTranscript,
                style: previousRequest.style, resolvedEnvironment: previousRequest.resolvedEnvironment,
                resolvedGuidance: previousRequest.resolvedGuidance, exactLiterals: previousRequest.exactLiterals,
                writingDefaults: previousRequest.writingDefaults)
            activeRequest = request
            await startGeneration(request, providerAction: providerAction, generation: expectedGeneration)
        } catch {
            guard generation == expectedGeneration, activeRequestID == requestID else { return true }
            failure = .context((error as? ScribeContextError) ?? .captureCleared)
            state = .failed(requestID: requestID, error: .unavailable)
        }
        return true
    }

    /// An explicit discard creates a new fact-free action from the same speech.
    /// It does not forget either memory store or change either setting.
    @discardableResult
    func regenerateWithoutSessionFacts(id: UUID) async -> Bool {
        await regenerateExcludingSessionFacts(sourceID: id, recordID: nil)
    }

    /// Discards one fact-backed draft and keeps the other frozen facts in a
    /// new action. A second exclusion compounds across both memory stores.
    @discardableResult
    func regenerateWithoutSessionFact(sourceID: UUID, recordID: UUID) async -> Bool {
        await regenerateExcludingSessionFacts(sourceID: sourceID, recordID: recordID)
    }

    private func regenerateExcludingSessionFacts(sourceID id: UUID, recordID: UUID?) async -> Bool {
        guard isReviewingDraft, !isStarting, !isRefining, !insertionOutcomeUncertain,
              let oldRequest = activeRequest, let oldResult = reviewedResult,
              oldResult.requestID == oldRequest.id, oldRequest.id == id,
              activeMemoryDraftFacts != nil || activePersistentDraftFacts != nil,
              activeSelectedTextSnapshot == nil,
              let capture = activeCapture, let providerAction = activeProviderAction,
              providerAction.destination == .legacyLocal,
              ensureMemoryDraftAuthorization() else { return false }
        let activeSession = activeMemoryDraftFacts
        let activeSaved = activePersistentDraftFacts
        let activeIDs = (activeSession?.recordIDs ?? []) + (activeSaved?.recordIDs ?? [])
        guard (activeSession == nil || activeSession?.recordIDs.count == activeSession?.texts.count),
              (activeSaved == nil || activeSaved?.recordIDs.count == activeSaved?.texts.count) else {
            return false
        }
        if let recordID, !activeIDs.contains(recordID) { return false }
        let fullSession = memoryExclusionBaseline ?? activeSession
        let fullSaved = persistentExclusionBaseline ?? activeSaved
        let fullIDs = (fullSession?.recordIDs ?? []) + (fullSaved?.recordIDs ?? [])
        guard (fullSession == nil || fullSession?.recordIDs.count == fullSession?.texts.count),
              (fullSaved == nil || fullSaved?.recordIDs.count == fullSaved?.texts.count),
              Set(fullIDs).count == fullIDs.count else { return false }
        let fullPairs = Array(zip(fullSession?.recordIDs ?? [], fullSession?.texts ?? []))
            + Array(zip(fullSaved?.recordIDs ?? [], fullSaved?.texts ?? []))
        let activePairs = Array(zip(activeSession?.recordIDs ?? [], activeSession?.texts ?? []))
            + Array(zip(activeSaved?.recordIDs ?? [], activeSaved?.texts ?? []))
        let selectedIDs: Set<UUID>
        if let recordID, let selected = activePairs.first(where: { $0.0 == recordID }) {
            // Two stores can contain the same exact fact. An omission must
            // remove both copies rather than quietly send the other one.
            selectedIDs = Set(fullPairs.filter { $0.1 == selected.1 }.map(\.0))
        } else {
            selectedIDs = Set(fullIDs)
        }
        let excludedIDs = memoryExcludedRecordIDs.union(selectedIDs)
        guard excludedIDs.isSubset(of: Set(fullIDs)) else { return false }
        let retainsSession = fullSession?.recordIDs.contains { !excludedIDs.contains($0) } == true
        let retainsSaved = fullSaved?.recordIDs.contains { !excludedIDs.contains($0) } == true

        let previousGeneration = generation
        do {
            guard try contextService.verifyTargetAllowingComposeReviewFocus(for: capture),
                  generation == previousGeneration, activeRequestID == id,
                  isReviewingDraft, !insertionOutcomeUncertain,
                  activeCapture == capture, reviewedResult == oldResult,
                  ensureMemoryDraftAuthorization() else { return false }
        } catch { return false }

        let originalTranscript = literalTranscript
        cancelOutstandingGeneration()
        let newGeneration = generation
        actionRevision &+= 1
        performanceRecorder?.finish(actionID: oldRequest.id, outcome: .cancelled)
        if !retainsSession { sessionMemoryContext?.clear(actionID: oldRequest.id) }
        if !retainsSaved { persistentMemoryContext?.clear(actionID: oldRequest.id) }
        clearContent()

        let requestID = UUID()
        let request = ScribeRequest(
            id: requestID, intent: .compose,
            spokenTranscript: oldRequest.spokenTranscript,
            style: oldRequest.style,
            resolvedEnvironment: oldRequest.resolvedEnvironment,
            resolvedGuidance: oldRequest.resolvedGuidance,
            exactLiterals: oldRequest.exactLiterals,
            writingDefaults: oldRequest.writingDefaults
        )
        activeRequestID = requestID
        activeRequest = request
        activeProviderAction = providerAction
        literalTranscript = originalTranscript
        resolvedEnvironment = oldRequest.resolvedEnvironment
        resolvedGuidance = oldRequest.resolvedGuidance
        exactLiterals = oldRequest.exactLiterals
        activeWritingDefaults = oldRequest.writingDefaults
        memoryExcludedActionID = requestID
        memoryExclusionBaseline = fullSession
        persistentExclusionBaseline = fullSaved
        memoryExcludedRecordIDs = excludedIDs
        memoryDraftSnapshotResolved = !retainsSession
        persistentDraftSnapshotResolved = !retainsSaved
        if retainsSession,
           sessionMemoryContext?.rebindAction(
                from: oldRequest.id, to: requestID,
                capture: capture, destination: providerAction.destination
           ) != true {
            invalidateMemoryBackedDraft(requestID: requestID)
            return true
        }
        if retainsSaved,
           persistentMemoryContext?.rebindAction(
                from: oldRequest.id, to: requestID, capture: capture
           ) != true {
            invalidateMemoryBackedDraft(requestID: requestID)
            return true
        }
        performanceRecorder?.begin(actionID: requestID)
        performanceRecorder?.mark(.targetPinned, actionID: requestID)
        state = .generating(requestID: requestID)
        await startGeneration(request, providerAction: providerAction, generation: newGeneration)
        return true
    }

    /// Refinement consumes only this in-memory draft. It never prepares or
    /// captures a target while Cadence's review controls own focus.
    func beginRefinement() async throws {
        guard canRefineReviewedDraft, let session = draftRevisionSession,
              let providerAction = activeProviderAction else {
            throw ScribeCoordinatorError.invalidState
        }
        try ScribeDraftRefinementPolicy.validateDestination(providerAction.destination)
        try validateRevisionOrigin(session.origin)
        cancelOutstandingGeneration()
        let expectedGeneration = generation
        let action = RefinementAction(id: UUID(), session: session, providerAction: providerAction)
        refinementAction = action
        failure = nil
        providerFailure = nil
        isStarting = true
        // Publish refinement ownership before an asynchronous microphone start,
        // so Escape already means cancel this revision rather than discard.
        onStateChange?(state)
        defer {
            isStarting = false
            onStateChange?(state)
        }
        do {
            guard let capture = activeCapture,
                  try contextService.verifyTarget(for: capture) else { throw ScribeContextError.targetChanged }
            voiceLease = try sessionArbiter.acquire(for: .scribe)
            try await transcriptionEngine.startSession()
            guard generation == expectedGeneration, refinementAction?.id == action.id else {
                throw CancellationError()
            }
            let (stream, continuation) = AsyncStream.makeStream(
                of: ScribeCapturedAudio.self, bufferingPolicy: .bufferingOldest(256)
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
            state = .listening(requestID: session.origin.actionID)
        } catch {
            guard generation == expectedGeneration, refinementAction?.id == action.id else { throw error }
            await finishAudioIngestion(cancel: true)
            await transcriptionEngine.cancelSession()
            releaseVoiceLease()
            if let contextError = error as? ScribeContextError {
                finishRefinement(failure: .context(contextError))
            } else if let arbiterError = error as? VoiceSessionArbiterError,
                      case let .busy(kind) = arbiterError {
                finishRefinement(failure: .voiceSessionBusy(kind))
            } else {
                finishRefinement(failure: .transcription)
            }
            throw error
        }
    }

    func undoRefinement() {
        guard canUndoRefinement, let session = draftRevisionSession,
              let restored = try? draftRevisionStore.undo(sessionID: session.id, origin: session.origin) else { return }
        cancelOutstandingGeneration()
        draftRevisionSession = restored
        exactLiterals = revisionLiterals[restored.currentVersion.id] ?? []
        let result = ScribeResult(requestID: restored.origin.actionID, text: restored.currentVersion.text)
        reviewedResult = result
        lastRefinementInstruction = nil
        failure = nil
        providerFailure = nil
        state = .reviewing(result)
    }

    func cancelRefinement() async {
        guard isRefining else { return }
        cancelOutstandingGeneration()
        if case .listening = state { _ = audioCaptureService.stopCapture() }
        await finishAudioIngestion(cancel: true)
        await transcriptionEngine.cancelSession()
        releaseVoiceLease()
        finishRefinement(failure: nil)
    }

    /// Dictation's synchronous acquisition callback fences a ready provider
    /// completion before asynchronous microphone/transcription cleanup begins.
    func invalidateRefinementCompletion() {
        guard isRefining else { return }
        cancelOutstandingGeneration()
    }

    private func finishRefinementRecording() async {
        guard case .listening = state, let action = refinementAction else { return }
        let expectedGeneration = generation
        let requestID = action.session.origin.actionID
        state = .transcribing(requestID: requestID)
        let metrics = audioCaptureService.stopCapture()
        await finishAudioIngestion(cancel: false)
        guard generation == expectedGeneration, refinementAction?.id == action.id else { return }
        do {
            let instruction = try await transcriptionEngine.finishSession(metrics: metrics)
                .cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == expectedGeneration, refinementAction?.id == action.id else { return }
            releaseVoiceLease()
            guard !instruction.isEmpty else {
                finishRefinement(failure: .transcriptionEmpty)
                return
            }
            lastRefinementInstruction = instruction
            if ScribeDraftRefinementPolicy.isUndoInstruction(instruction) {
                finishRefinement(failure: nil)
                undoRefinement()
                return
            }
            guard let originalRequest = activeRequest else { throw ScribeDraftRefinementError.invalidOrigin }
            let processed = VocabularyPostProcessor.apply(to: instruction, configuration: localTextConfiguration)
            let normalized = ScribeLiteralNormalizer.normalize(
                processed, environmentID: resolvedEnvironment?.environmentID ?? .global
            )
            guard normalized.parseStatus == .clean else {
                finishRefinement(failure: .literalRepair)
                return
            }
            let token = try draftRevisionStore.beginRevision(
                sessionID: action.session.id, origin: action.session.origin,
                baseVersionID: action.session.currentVersion.id, revisionUtterance: normalized.text
            )
            refinementAction?.token = token
            let request = try ScribeDraftRefinementPolicy.request(
                token: token, session: action.session, originalRequest: originalRequest,
                instructionLiterals: exactLiterals + normalized.exactLiterals
            )
            await startRefinementGeneration(request, action: action, generation: expectedGeneration)
        } catch WhisperEngineError.emptyAudio, WhisperEngineError.noTranscript {
            guard generation == expectedGeneration, refinementAction?.id == action.id else { return }
            releaseVoiceLease()
            finishRefinement(failure: .transcriptionEmpty)
        } catch {
            guard generation == expectedGeneration, refinementAction?.id == action.id else { return }
            releaseVoiceLease()
            finishRefinement(failure: .transcription)
        }
    }

    private func startRefinementGeneration(
        _ request: ScribeDraftRefinementRequest,
        action: RefinementAction,
        generation expectedGeneration: Int
    ) async {
        let providerAction = action.providerAction
        do {
            try ScribeDraftRefinementPolicy.validateDestination(providerAction.destination)
            guard await providerDispatchAuthorization(providerAction) else { throw ScribeProviderError.unavailable }
            guard generation == expectedGeneration, refinementAction?.token == request.token else { return }
            try validateRevisionOrigin(request.token.origin)
            guard let capture = activeCapture,
                  try contextService.verifyTarget(for: capture) else { throw ScribeContextError.targetChanged }
            let input = try ScribeDraftRefinementPolicy.providerSafeInput(for: request, destination: providerAction.destination)
            guard providerAction.provider.capabilities.contains(.semanticGeneration) else {
                throw ScribeProviderCapabilityRejection.unavailable
            }
            try ScribeProviderCapabilityPolicy.validate(
                input: input, profile: providerAction.capabilityProfile, requirements: .draftRefinement
            )
            attemptRevision &+= 1
            let providerRequest = ScribeProviderRequest(
                id: request.token.id, input: input,
                resultBinding: .init(
                    requestID: request.token.id, actionRevision: actionRevision, attemptRevision: attemptRevision,
                    providerKind: providerAction.destination.providerKind, modelID: providerAction.selectedModelID
                )
            )
            let attemptID = UUID()
            activeAttemptID = attemptID
            activeProviderRequest = providerRequest
            state = .generating(requestID: request.token.origin.actionID)
            softWaitTask?.cancel()
            softWaitTask = Task { @MainActor [weak self, generationSoftWait] in
                do { try await Task.sleep(for: generationSoftWait) } catch { return }
                guard let self, self.generation == expectedGeneration,
                      self.activeAttemptID == attemptID, self.refinementAction?.token == request.token else { return }
                self.state = .generatingSlow(requestID: request.token.origin.actionID)
            }
            let task = Task { [weak self, provider = providerAction.provider, generationTimeout] in
                do {
                    let result = try await Self.generate(providerRequest, provider: provider, timeout: generationTimeout)
                    guard let self, !Task.isCancelled, self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID, self.refinementAction?.token == request.token else { return }
                    guard result.requestID == providerRequest.id, result.binding == providerRequest.resultBinding else {
                        throw ScribeProviderError.invalidResult
                    }
                    try self.validateRevisionOrigin(request.token.origin)
                    let normalizedOutput = ScribeDraftRefinementPolicy.reviseUnchangedOutput(
                        try ScribeOutputPolicy.normalizedOutput(result.text), for: request
                    )
                    // Keep the already reviewed version when the model made no
                    // change, including when it missed a newly requested rule.
                    guard Data(normalizedOutput.utf8) != Data(request.baseDraft.utf8) else {
                        self.finishRefinement(failure: .refinementUnchanged)
                        return
                    }
                    let validated = try ScribeDraftRefinementPolicy.validateOutput(normalizedOutput, for: request)
                    let session = try self.draftRevisionStore.completeRevision(request.token, refinedDraft: validated)
                    self.draftRevisionSession = session
                    let outputBytes = Data(validated.utf8)
                    self.exactLiterals = request.exactLiterals.filter { outputBytes.range(of: Data($0.value.utf8)) != nil }
                    self.revisionLiterals[session.currentVersion.id] = self.exactLiterals
                    let retainedVersions = Set(session.versions.map(\.id))
                    self.revisionLiterals = self.revisionLiterals.filter { retainedVersions.contains($0.key) }
                    self.reviewedResult = ScribeResult(requestID: session.origin.actionID, text: validated, binding: result.binding)
                    self.finishRefinement(failure: nil)
                } catch {
                    guard let self, !Task.isCancelled, self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID, self.refinementAction?.token == request.token else { return }
                    self.handleRefinementFailure(error)
                }
            }
            generationTask = task
            await task.value
            guard generation == expectedGeneration else { return }
            generationTask = nil
            softWaitTask?.cancel()
            softWaitTask = nil
        } catch {
            guard generation == expectedGeneration, refinementAction?.id == action.id else { return }
            handleRefinementFailure(error)
        }
    }

    private func handleRefinementFailure(_ error: Error) {
        if let error = error as? ScribeContextError {
            finishRefinement(failure: .context(error))
        } else if let rejection = error as? ScribeProviderCapabilityRejection {
            finishRefinement(failure: .capability(rejection))
        } else if error is ScribeRecipientRestrictionValidationError {
            finishRefinement(failure: .recipientRestriction)
        } else if let error = error as? ScribeProviderError {
            finishRefinement(failure: .provider(error))
        } else {
            finishRefinement(failure: .provider(.invalidResult))
        }
    }

    private func finishRefinement(failure: ScribeSessionFailure?) {
        if let token = refinementAction?.token { _ = try? draftRevisionStore.discardRevision(token) }
        refinementAction = nil
        activeProviderRequest = nil
        activeAttemptID = nil
        self.failure = failure
        providerFailure = nil
        if let reviewedResult { state = .reviewing(reviewedResult) }
    }

    private func validateRevisionOrigin(_ origin: ScribeDraftRevisionOrigin) throws {
        guard let capture = activeCapture, origin.actionID == activeRequestID,
              origin.captureID == capture.id, origin.target == capture.target,
              origin.providerActionIdentity == activeProviderAction?.actionIdentity,
              draftRevisionSession?.origin == origin else { throw ScribeDraftRefinementError.invalidOrigin }
    }

    private func startDraftRevisionSession(_ result: ScribeResult) {
        guard let capture = activeCapture, let literalTranscript else { return }
        draftRevisionStore = ScribeDraftRevisionStore()
        draftRevisionSession = draftRevisionStore.start(
            origin: .init(
                actionID: result.requestID, captureID: capture.id, target: capture.target,
                providerActionIdentity: activeProviderAction?.actionIdentity
            ),
            originalSpokenRequest: literalTranscript, initialDraft: result.text
        )
        revisionLiterals = draftRevisionSession.map { [$0.currentVersion.id: exactLiterals] } ?? [:]
        lastRefinementInstruction = nil
    }

    func insertReviewedResult() async throws {
        guard !isRefining, !isSelectedTextSourceExcluded,
              failure != .selectedTextUnchanged else { throw ScribeCoordinatorError.invalidState }
        guard !insertionCompleted, insertionAttemptID == nil, !insertionOutcomeUncertain else {
            throw ScribeCoordinatorError.insertionAlreadyCompleted
        }
        guard let result = reviewedResult else {
            throw ScribeCoordinatorError.invalidState
        }
        guard ensureMemoryDraftAuthorization() else { throw ScribeContextError.captureCleared }
        try await insert(result, source: .polished)
    }

    func insertUnpolishedResult() async throws {
        guard !isRefining else { throw ScribeCoordinatorError.invalidState }
        guard !insertionCompleted, insertionAttemptID == nil, !insertionOutcomeUncertain else {
            throw ScribeCoordinatorError.insertionAlreadyCompleted
        }
        guard let requestID = activeRequestID,
              let literalTranscript = literalRecoveryTranscript,
              !literalTranscript.isEmpty else {
            throw ScribeCoordinatorError.invalidState
        }
        try await insert(ScribeResult(requestID: requestID, text: literalTranscript), source: .unpolished)
    }

    private enum InsertSource { case polished, unpolished }

    private func insert(_ result: ScribeResult, source: InsertSource) async throws {
        guard !insertionCompleted, insertionAttemptID == nil, !insertionOutcomeUncertain else {
            throw ScribeCoordinatorError.insertionAlreadyCompleted
        }
        guard let capture = activeCapture else {
            throw ScribeCoordinatorError.invalidState
        }
        guard ensureSelectedTextAuthorization() else { throw ScribeContextError.captureCleared }
        if source == .polished {
            guard ensureMemoryDraftAuthorization() else { throw ScribeContextError.captureCleared }
        }
        let insertedMemoryDraft = source == .polished
            && (activeMemoryDraftFacts != nil || activePersistentDraftFacts != nil)
        let attemptID = UUID()
        insertionAttemptID = attemptID
        defer {
            if insertionAttemptID == attemptID { insertionAttemptID = nil }
        }

        // Selecting an action is terminal for any retained retry. A late
        // completion cannot replace, resurrect, or redirect this draft.
        cancelOutstandingGeneration()
        let insertionGeneration = generation
        let selectedSource = source == .polished ? activeSelectedTextSnapshot : nil
        state = .inserting(requestID: result.requestID)
        performanceRecorder?.mark(.insertionAttempted, actionID: result.requestID)
        do {
            let inserted: Bool
            if let selectedSource {
                inserted = try await contextService.insert(result.text, for: capture, selectedTextPreflight: { [weak self] in
                    guard let self, self.generation == insertionGeneration,
                          self.activeSelectedTextSnapshot == selectedSource,
                          self.ensureSelectedTextAuthorization(),
                          let context = self.selectedTextContext else { return false }
                    let revalidation = await context.revalidateSelection(selectedSource)
                    return revalidation == .current && self.generation == insertionGeneration
                        && self.activeSelectedTextSnapshot == selectedSource
                        && self.ensureSelectedTextAuthorization()
                })
            } else if insertedMemoryDraft {
                inserted = try await contextService.insert(
                    result.text, for: capture, selectedTextPreflight: { [weak self] in
                        guard let self,
                              self.generation == insertionGeneration,
                              let request = self.activeRequest,
                              let destination = self.activeProviderAction?.destination else { return false }
                        return self.memoryDraftFactsStillCurrent(for: request, destination: destination)
                    }
                )
            } else {
                inserted = try await contextService.insert(result.text, for: capture)
            }
            guard generation == insertionGeneration else { throw ScribeContextError.captureCleared }
            guard inserted else {
                throw ScribeContextError.unsupportedSelection
            }
            insertionCompleted = true
            if source == .polished { recordReviewedDraftChoice(.inserted, result: result) }
            clearContext()
            clearContent()
            state = .succeeded(requestID: result.requestID)
        } catch let error as ScribeContextError {
            if insertedMemoryDraft,
               let request = activeRequest, let destination = activeProviderAction?.destination,
               !memoryDraftFactsStillCurrent(for: request, destination: destination) {
                invalidateMemoryBackedDraft(requestID: result.requestID)
                throw ScribeContextError.captureCleared
            }
            guard generation == insertionGeneration else { throw error }
            if error == .insertionUnconfirmed { insertionOutcomeUncertain = true }
            failure = .context(error)
            // `reviewedResult` is intentionally untouched for an unpolished
            // insertion attempt. Recovery always preserves both routes.
            state = source == .polished ? .insertionRecovery(result) : (reviewedResult.map(ScribeSessionState.insertionRecovery) ?? .failed(requestID: result.requestID, error: .unavailable))
            throw error
        } catch {
            // The event emitter can fail after posting some events. Do not
            // leave the session stuck in `inserting` or imply nothing landed.
            guard generation == insertionGeneration else { throw error }
            let recoveryError = ScribeContextError.insertionUnconfirmed
            insertionOutcomeUncertain = true
            failure = .context(recoveryError)
            state = source == .polished ? .insertionRecovery(result) : (reviewedResult.map(ScribeSessionState.insertionRecovery) ?? .failed(requestID: result.requestID, error: .unavailable))
            throw recoveryError
        }
    }

    func takeReviewedDraftForCopy() -> String? {
        guard ensureSelectedTextAuthorization() else { return nil }
        guard ensureMemoryDraftAuthorization() else { return nil }
        return reviewedResult?.text
    }

    func noteReviewedDraftCopied() {
        guard let reviewedResult else { return }
        recordReviewedDraftChoice(.copied, result: reviewedResult)
    }

    private func recordReviewedDraftChoice(_ selection: ScribeSessionMemoryDraftSelection, result: ScribeResult) {
        guard !isSelectedTextRewriteAction, activeSelectedTextSnapshot == nil,
              activeMemoryDraftFacts == nil, activePersistentDraftFacts == nil,
              activeRequestID == result.requestID, reviewedResult == result,
              let capture = activeCapture,
              let session = draftRevisionSession,
              session.origin.actionID == result.requestID,
              session.origin.captureID == capture.id,
              session.currentVersion.text == result.text,
              let destination = activeProviderAction?.destination,
              destination == .legacyLocal else { return }
        sessionMemoryContext?.rememberChosenDraft(
            result.text, draftID: session.currentVersion.id, selection: selection,
            actionID: result.requestID, capture: capture, destination: destination
        )
    }

    func reviewedHistoryDraft() -> ComposeHistoryDraft? {
        // Local capture consent does not grant retention of a derivative.
        guard ensureSelectedTextAuthorization(), ensureMemoryDraftAuthorization(),
              activeMemoryDraftFacts == nil,
              activePersistentDraftFacts == nil,
              !isSelectedTextRewriteAction, let reviewedResult,
              let literalTranscript,
              !literalTranscript.isEmpty else { return nil }
        return ComposeHistoryDraft(
            requestID: reviewedResult.requestID,
            originalText: literalTranscript,
            composedText: reviewedResult.text
        )
    }

    func takeUnpolishedDraftForCopy() -> String? {
        guard let literalTranscript = literalRecoveryTranscript,
              !literalTranscript.isEmpty else { return nil }
        return literalTranscript
    }

    func unpolishedHistoryDraft() -> ComposeHistoryDraft? {
        guard let requestID = activeRequestID,
              let literalTranscript = literalRecoveryTranscript,
              !literalTranscript.isEmpty else { return nil }
        return ComposeHistoryDraft(
            requestID: requestID,
            originalText: literalTranscript,
            composedText: nil
        )
    }

    func cancel() async {
        let cancelledRequestID = activeRequestID
        cancelOutstandingGeneration()
        // Revoke optional content synchronously, before microphone/engine
        // teardown can suspend. Cancelled drafts may not remain copyable.
        selectedTextContext?.clear(actionID: nil)
        if isSelectedTextRewriteAction { clearContent() }

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

    func dismissPanel() async {
        await cancel()
        state = .idle
    }

    private func startGeneration(
        _ request: ScribeRequest,
        providerAction: ScribeProviderActionSnapshot,
        generation expectedGeneration: Int
    ) async {
        let authorized = await providerDispatchAuthorization(providerAction)
        guard generation == expectedGeneration, activeRequestID == request.id else { return }
        guard authorized else {
            // Authorization is a narrow egress gate.  A denial must not
            // destructively cancel a previously reviewed draft or clear its
            // processed dictation/target needed for local recovery.
            activeProviderRequest = nil
            activeAttemptID = nil
            retainReviewedDraftOrFail(
                .provider(.unavailable),
                requestID: request.id
            )
            return
        }
        guard generation == expectedGeneration, activeRequestID == request.id,
              ensureSelectedTextAuthorization() else { return }
        do {
            // The authorization closure can suspend while settings, consent,
            // or the focused target changes. Re-check the exact pinned target
            // immediately before building any request or dispatching egress.
            guard let activeCapture,
                  try (request.id == memoryExcludedActionID
                    ? contextService.verifyTargetAllowingComposeReviewFocus(for: activeCapture)
                    : contextService.verifyTarget(for: activeCapture)) else {
                throw ScribeContextError.targetChanged
            }
        } catch let error as ScribeContextError {
            retainReviewedDraftOrFail(.context(error), requestID: request.id)
            return
        } catch {
            retainReviewedDraftOrFail(.context(.targetChanged), requestID: request.id)
            return
        }
        failure = nil
        providerFailure = nil
        attemptRevision &+= 1
        let binding = ScribeProviderResultBinding(
            requestID: request.id,
            actionRevision: actionRevision,
            attemptRevision: attemptRevision,
            providerKind: providerAction.destination.providerKind,
            modelID: providerAction.selectedModelID
        )
        let providerRequest: ScribeProviderRequest
        let selectedSource = activeSelectedTextSnapshot
        let selectedCompilation: ComposeGroundedCompilation?
        do {
            let input: ProviderSafeScribeInput
            if let selectedSource {
                guard let selectedTextContext else { throw ComposeGroundedCompilationError.invalidAuthority }
                let compilation = try selectedTextContext.compileRewrite(
                    request, using: selectedSource, destination: providerAction.destination
                )
                selectedCompilation = compilation
                input = compilation.input
            } else {
                selectedCompilation = nil
                guard let capture = activeCapture else {
                    retainReviewedDraftOrFail(.context(.targetChanged), requestID: request.id)
                    return
                }
                let memoryFacts: ComposeSessionMemoryDraftFacts?
                let persistentFacts: ComposeSessionMemoryDraftFacts?
                do {
                    let sourceFacts = !requiresMemoryRead(
                        baseline: memoryExclusionBaseline, for: request.id
                    ) ? nil
                        : try sessionMemoryContext?.draftFacts(
                            for: request.spokenTranscript, actionID: request.id,
                            capture: capture, destination: providerAction.destination
                        )
                    memoryFacts = try applyingMemoryExclusions(
                        sourceFacts, baseline: memoryExclusionBaseline, for: request.id
                    )
                    let readPersistent = requiresMemoryRead(
                        baseline: persistentExclusionBaseline, for: request.id
                    )
                    if readPersistent, request.id != memoryExcludedActionID,
                       providerAction.destination == .legacyLocal,
                       let persistentMemoryContext,
                       persistentMemoryContext.permitsLocalDraftUse {
                        _ = persistentMemoryContext.begin(actionID: request.id, capture: capture)
                    }
                    let sourcePersistentFacts: ComposeSessionMemoryDraftFacts?
                    if readPersistent {
                        sourcePersistentFacts = try persistentMemoryContext?.draftFacts(
                            for: request.spokenTranscript, actionID: request.id,
                            capture: capture, destination: providerAction.destination
                        )
                    } else {
                        sourcePersistentFacts = nil
                    }
                    persistentFacts = try applyingMemoryExclusions(
                        sourcePersistentFacts, baseline: persistentExclusionBaseline, for: request.id
                    )
                } catch ComposeSessionMemoryContextError.ambiguousFollowUp {
                    if activeMemoryDraftFacts != nil || activePersistentDraftFacts != nil {
                        invalidateMemoryBackedDraft(requestID: request.id)
                    } else {
                        retainReviewedDraftOrFail(.memoryAmbiguous, requestID: request.id)
                    }
                    return
                } catch ComposeSessionMemoryContextError.unavailable {
                    invalidateMemoryBackedDraft(requestID: request.id)
                    return
                } catch {
                    retainReviewedDraftOrFail(.memoryUnavailable, requestID: request.id)
                    return
                }
                if memoryDraftSnapshotResolved {
                    guard memoryFacts == activeMemoryDraftFacts else {
                        invalidateMemoryBackedDraft(requestID: request.id)
                        return
                    }
                } else {
                    activeMemoryDraftFacts = memoryFacts
                    memoryDraftSnapshotResolved = true
                }
                if persistentDraftSnapshotResolved {
                    guard persistentFacts == activePersistentDraftFacts else {
                        invalidateMemoryBackedDraft(requestID: request.id)
                        return
                    }
                } else {
                    activePersistentDraftFacts = persistentFacts
                    persistentDraftSnapshotResolved = true
                }
                let allFactTexts = (memoryFacts?.texts ?? []) + (persistentFacts?.texts ?? [])
                guard allFactTexts.count <= 6,
                      allFactTexts.reduce(0, { $0 + $1.utf8.count }) <= 8_192 else {
                    retainReviewedDraftOrFail(.memoryUnavailable, requestID: request.id)
                    return
                }
                input = try ScribeRequestPolicy.providerSafeInput(
                    for: request, destination: providerAction.destination,
                    memoryFacts: allFactTexts
                )
            }
            guard providerAction.provider.capabilities.contains(.semanticGeneration) else {
                throw ScribeProviderCapabilityRejection.unavailable
            }
            try ScribeProviderCapabilityPolicy.validate(
                input: input,
                profile: providerAction.capabilityProfile,
                requirements: selectedSource == nil ? .directTextDraft : .selectedTextRewrite
            )
            providerRequest = ScribeProviderRequest(
                id: request.id,
                input: input,
                resultBinding: binding
            )
            activeSelectedTextCompilation = selectedCompilation
        } catch let error as ComposeGroundedCompilationError {
            switch error {
            case .voiceTooLarge, .sourceTooLarge, .requiredSourceTooLarge:
                retainReviewedDraftOrFail(.provider(.inputTooLarge), requestID: request.id)
            default:
                selectedTextAccessRevoked(actionID: request.id)
            }
            return
        } catch let rejection as ScribeProviderCapabilityRejection {
            retainReviewedDraftOrFail(.capability(rejection), requestID: request.id)
            return
        } catch {
            retainReviewedDraftOrFail(.provider(.invalidResult), requestID: request.id)
            return
        }
        state = .generating(requestID: request.id)
        performanceRecorder?.mark(.generationStarted, actionID: request.id)
        activeProviderRequest = providerRequest
        let attemptID = UUID()
        activeAttemptID = attemptID
        let recipientRestrictions = ScribeRecipientRestrictionPolicy.extract(from: selectedSource?.selectedText ?? request.spokenTranscript)
        let requiredLiterals = selectedSource.map { ComposeSelectedTextRewritePolicy.protectedLiterals(in: $0.selectedText) } ?? request.exactLiterals
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
                guard result.requestID == request.id,
                      result.binding == providerRequest.resultBinding else {
                    throw ScribeProviderError.invalidResult
                }
                let validatedText: String
                if let selectedCompilation {
                    let normalized = try ScribeOutputPolicy.normalizedOutput(result.text)
                    let effective = selectedSource.map {
                        ComposeSelectedTextRewritePolicy.reviseBoundedOutput(
                            normalized, source: $0.selectedText, instruction: request.spokenTranscript
                        )
                    } ?? normalized
                    validatedText = try ComposeContextCompiler.validateOutput(effective, for: selectedCompilation)
                } else {
                    validatedText = try ScribeRequestPolicy.validateOutput(
                        result.text, requiredLiterals: requiredLiterals,
                        spokenRequest: request.spokenTranscript, literalMutationAuthorization: request.spokenTranscript
                    )
                    try ScribeRequestPolicy.validateDirectDraftDirectionSeparation(
                        validatedText, spokenRequest: request.spokenTranscript,
                        protectedValues: requiredLiterals.map(\.value)
                    )
                    try ScribeRequestPolicy.validateDirectDraftUncertainty(
                        validatedText, spokenRequest: request.spokenTranscript,
                        protectedValues: requiredLiterals.map(\.value)
                    )
                    try ScribeRequestPolicy.validateDirectDraftRecipient(
                        validatedText, spokenRequest: request.spokenTranscript,
                        protectedValues: requiredLiterals.map(\.value)
                    )
                    try ScribeRecipientRestrictionPolicy.validate(output: validatedText, requirements: recipientRestrictions)
                }
                let validatedResult = ScribeResult(
                    requestID: request.id,
                    text: validatedText,
                    binding: result.binding
                )
                await MainActor.run { [weak self] in
                    guard let self,
                          self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID,
                          self.activeSelectedTextSnapshot == selectedSource,
                          self.ensureSelectedTextAuthorization() else { return }
                    guard self.memoryDraftFactsStillCurrent(for: request, destination: providerAction.destination) else {
                        self.invalidateMemoryBackedDraft(requestID: request.id)
                        return
                    }
                    self.reviewedResult = validatedResult
                    self.startDraftRevisionSession(validatedResult)
                    self.failure = selectedSource.map { Data($0.selectedText.utf8) == Data(validatedText.utf8) } == true
                        ? .selectedTextUnchanged : nil
                    self.providerFailure = nil
                    self.state = .reviewing(validatedResult)
                    self.performanceRecorder?.mark(.reviewReady, actionID: request.id)
                }
            } catch is ScribeRecipientRestrictionValidationError {
                await MainActor.run { [weak self] in
                    guard let self, self.generation == expectedGeneration,
                          self.activeAttemptID == attemptID else { return }
                    self.retainReviewedDraftOrFail(.recipientRestriction, requestID: request.id)
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
        if reviewedResult != nil {
            retainReviewedDraftOrFail(.provider(error), requestID: requestID)
            return
        }
        providerFailure = nil
        failure = .provider(error)
        state = .failed(requestID: requestID, error: error)
    }

    private func cancelOutstandingGeneration() {
        generation &+= 1
        generationTask?.cancel()
        generationTask = nil
        softWaitTask?.cancel()
        softWaitTask = nil
        activeAttemptID = nil
    }

    private func setProviderFailure(_ error: ScribeProviderFailure, requestID: UUID) {
        if reviewedResult != nil {
            providerFailure = error
            let legacyError: ScribeProviderError
            switch error.category {
            case .transportUnavailable: legacyError = .offline
            case .timedOut: legacyError = .timedOut
            case .cancelled: legacyError = .cancelled
            case .invalidResponse: legacyError = .invalidResult
            default: legacyError = .unavailable
            }
            retainReviewedDraftOrFail(.provider(legacyError), requestID: requestID)
            return
        }
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

    /// Preserve an already reviewed draft whenever a later retry or egress
    /// checkpoint fails.  The visible reviewing state keeps copy/insert
    /// available and `failure` still tells the panel why retry stopped.
    private func retainReviewedDraftOrFail(
        _ sessionFailure: ScribeSessionFailure,
        requestID: UUID
    ) {
        failure = sessionFailure
        activeProviderRequest = nil
        activeAttemptID = nil
        if let reviewedResult {
            state = .reviewing(reviewedResult)
            return
        }
        switch sessionFailure {
        case let .provider(error):
            state = .failed(requestID: requestID, error: error)
        case .context:
            state = .failed(requestID: requestID, error: .unavailable)
        default:
            state = .failed(requestID: requestID, error: .unavailable)
        }
    }

    private func releaseVoiceLease() {
        guard let voiceLease else { return }
        sessionArbiter.release(voiceLease)
        self.voiceLease = nil
    }

    private func clearContext() {
        selectedTextContext?.clear(actionID: nil)
        sessionMemoryContext?.clear(actionID: activeRequestID)
        persistentMemoryContext?.clear(actionID: activeRequestID)
        activeSelectedTextSnapshot = nil
        activeSelectedTextCompilation = nil
        guard let activeCapture else { return }
        contextService.clear(activeCapture)
        onTargetClear?(activeCapture.applicationTarget.id)
        self.activeCapture = nil
    }

    private func finishPerformanceIfTerminal(_ state: ScribeSessionState) {
        switch state {
        case let .succeeded(requestID):
            performanceRecorder?.finish(actionID: requestID, outcome: .completed)
        case let .memoryNotice(notice):
            performanceRecorder?.finish(actionID: notice.requestID, outcome: .completed)
        case let .cancelled(requestID):
            if let requestID { performanceRecorder?.finish(actionID: requestID, outcome: .cancelled) }
        case let .failed(requestID, _):
            if let requestID { performanceRecorder?.finish(actionID: requestID, outcome: .failed) }
        default:
            break
        }
    }

    private func resetTransientState() {
        generationTask?.cancel()
        generationTask = nil
        softWaitTask?.cancel()
        softWaitTask = nil
        clearContext()
        clearContent()
        insertionCompleted = false
        insertionAttemptID = nil
        insertionOutcomeUncertain = false
    }

    private func clearContent() {
        activeWritingDefaults = []
        isSelectedTextSourceExcluded = false
        isSelectedTextRewriteAction = false
        selectedTextContext?.clear(actionID: nil)
        activeSelectedTextSnapshot = nil
        activeSelectedTextCompilation = nil
        refinementAction = nil
        draftRevisionSession = nil
        draftRevisionStore = ScribeDraftRevisionStore()
        revisionLiterals = [:]
        lastRefinementInstruction = nil
        activeRequest = nil
        activeProviderRequest = nil
        activeProviderAction = nil
        activeMemoryDraftFacts = nil
        activePersistentDraftFacts = nil
        activePersistentMemoryProposal = nil
        activePersistentForgetProposal = nil
        isPersistentMemoryCommandAction = false
        memoryDraftSnapshotResolved = false
        persistentDraftSnapshotResolved = false
        memoryExcludedActionID = nil
        memoryExclusionBaseline = nil
        persistentExclusionBaseline = nil
        memoryExcludedRecordIDs = []
        activeAttemptID = nil
        activeRequestID = nil
        literalTranscript = nil
        reviewedResult = nil
        failure = nil
        providerFailure = nil
        resolvedEnvironment = nil
        resolvedGuidance = nil
        exactLiterals = []
    }

    private func ensureSelectedTextAuthorization() -> Bool {
        guard let snapshot = activeSelectedTextSnapshot else { return true }
        guard selectedTextContext?.authorizationIsCurrent(for: snapshot) == true else {
            selectedTextAccessRevoked(actionID: snapshot.target.action.actionID)
            return false
        }
        if let compilation = activeSelectedTextCompilation,
           selectedTextContext?.compilationIsCurrent(compilation, using: snapshot) != true {
            selectedTextAccessRevoked(actionID: snapshot.target.action.actionID)
            return false
        }
        return true
    }

    private func memoryDraftFactsStillCurrent(
        for request: ScribeRequest, destination: ScribeEgressDestination
    ) -> Bool {
        guard activeMemoryDraftFacts != nil || activePersistentDraftFacts != nil else { return true }
        guard let capture = activeCapture else { return false }
        if let expected = activeMemoryDraftFacts {
            guard let sourceFacts = try? sessionMemoryContext?.draftFacts(
                for: request.spokenTranscript, actionID: request.id,
                capture: capture, destination: destination
            ), let current = try? applyingMemoryExclusions(
                sourceFacts, baseline: memoryExclusionBaseline, for: request.id
            ),
                  current == expected else { return false }
        }
        if let expected = activePersistentDraftFacts {
            guard let sourceFacts = try? persistentMemoryContext?.draftFacts(
                for: request.spokenTranscript, actionID: request.id,
                capture: capture, destination: destination
            ), let current = try? applyingMemoryExclusions(
                sourceFacts, baseline: persistentExclusionBaseline, for: request.id
            ), current == expected else { return false }
        }
        return true
    }

    private func requiresMemoryRead(
        baseline: ComposeSessionMemoryDraftFacts?, for requestID: UUID
    ) -> Bool {
        guard requestID == memoryExcludedActionID else { return true }
        guard let baseline else { return false }
        return baseline.recordIDs.contains { !memoryExcludedRecordIDs.contains($0) }
    }

    private func applyingMemoryExclusions(
        _ sourceFacts: ComposeSessionMemoryDraftFacts?,
        baseline: ComposeSessionMemoryDraftFacts?, for requestID: UUID
    ) throws -> ComposeSessionMemoryDraftFacts? {
        guard requestID == memoryExcludedActionID else { return sourceFacts }
        guard let baseline else { return nil }
        if !requiresMemoryRead(baseline: baseline, for: requestID) { return nil }
        guard sourceFacts == baseline,
              baseline.recordIDs.count == baseline.texts.count else {
            throw ComposeSessionMemoryContextError.unavailable
        }
        let retained = zip(baseline.recordIDs, baseline.texts).filter {
            !memoryExcludedRecordIDs.contains($0.0)
        }
        guard !retained.isEmpty else { return nil }
        return .init(
            recordIDs: retained.map(\.0), texts: retained.map(\.1),
            localUseRevision: baseline.localUseRevision
        )
    }

    private func ensureMemoryDraftAuthorization() -> Bool {
        guard activeMemoryDraftFacts != nil || activePersistentDraftFacts != nil else { return true }
        guard let request = activeRequest,
              let destination = activeProviderAction?.destination,
              memoryDraftFactsStillCurrent(for: request, destination: destination) else {
            invalidateMemoryBackedDraft(requestID: activeRequestID)
            return false
        }
        return true
    }

    private func invalidateMemoryBackedDraft(requestID: UUID?) {
        cancelOutstandingGeneration()
        clearContext()
        clearContent()
        failure = .memoryUnavailable
        state = .failed(requestID: requestID, error: .unavailable)
    }

    private func selectedTextAccessRevoked(actionID: UUID) {
        // Pending optional capture does not own the microphone or ordinary
        // speech. Once used, revoke every draft/version derived from it.
        guard isSelectedTextRewriteAction, activeRequestID == actionID else { return }
        cancelOutstandingGeneration()
        clearContext()
        clearContent()
        failure = .context(.captureCleared)
        state = .failed(requestID: actionID, error: .unavailable)
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
        case .succeeded, .memoryNotice, .cancelled, .failed:
            return true
        default:
            return false
        }
    }
}
