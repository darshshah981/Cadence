import Foundation
import Testing
@testable import Cadence

@MainActor
struct ScribeCoordinatorTests {
    @Test
    func v2ControllerRevocationBetweenSnapshotAndDispatchMakesZeroTransportRequests() async throws {
        let library = U5LibraryStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library,
            legacyStore: U5LegacyStore(),
            ledgerStore: U5LedgerStore(),
            vault: vault
        )
        let receipt = ScribeProviderConsentIssuer.issue(
            providerKind: .openAIDirect,
            recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies,
            disclosureRevision: ScribeProviderDisclosure.currentVersion,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let reference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "coordinator-v2")
        )
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: receipt, reference: reference
        )
        let configured = ScribeProviderLibrary(
            revision: 2, configurations: [configuration], activeConfigurationID: configuration.id
        )
        library.result = .valid(configured)
        await vault.insert(reference)
        await authority.bootstrap(from: configured)
        let transport = U4RecordingTransport(results: [])
        let controller = ScribeProviderV2Controller(
            libraryStore: library,
            vault: vault,
            consentAuthority: authority,
            reconciler: reconciler,
            transport: transport
        )
        let fixture = ScribeCoordinatorFixture(
            providerActionResolver: { try await controller.actionForNewRequest() },
            providerDispatchAuthorization: { action in
                await controller.authorizeDispatch(action.actionIdentity)
            }
        )

        try await fixture.coordinator.begin(intent: .compose)
        await authority.revoke(receipt.id)
        await fixture.coordinator.finishRecording()

        #expect(await transport.requests.isEmpty)
        if case .cancelled = fixture.coordinator.state {
            // Expected exact V2 checkpoint rejection before transport.
        } else {
            Issue.record("Expected cancellation after consent revocation")
        }
    }

    @Test
    func defaultsNotificationInvalidationCancelsActiveCoordinatorAndStopsProvider() async throws {
        let runtime = try AdaptiveRuntimeFixture()
        defer { runtime.cleanUp() }
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in runtime.monitor.authorizeProviderDispatch() }
        )
        var cancellation: Task<Void, Never>?
        runtime.monitor.onInvalidation = {
            fixture.coordinator.invalidateProviderWork()
            cancellation = Task { @MainActor in await fixture.coordinator.cancel() }
        }
        runtime.monitor.start()
        #expect(runtime.monitor.revalidate())
        try await fixture.coordinator.begin(intent: .compose)

        try runtime.gateStore.save(.allDisabled)
        runtime.notificationCenter.post(
            name: UserDefaults.didChangeNotification,
            object: runtime.defaults
        )
        for _ in 0..<1_000 where cancellation == nil { await Task.yield() }
        await cancellation?.value
        await fixture.coordinator.finishRecording()

        if case .cancelled = fixture.coordinator.state {
            // Expected invalidation cleanup.
        } else {
            Issue.record("Expected notification-triggered cancellation")
        }
        #expect(await provider.requests.isEmpty)
        #expect(fixture.arbiter.activeKind == nil)
    }

    @Test
    func preDispatchCheckpointRejectsGateMutationWithoutWaitingForNotification() async throws {
        let runtime = try AdaptiveRuntimeFixture()
        defer { runtime.cleanUp() }
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            providerDispatchAuthorization: { _ in runtime.monitor.authorizeProviderDispatch() }
        )
        try await fixture.coordinator.begin(intent: .compose)
        try runtime.gateStore.save(.allDisabled)

        await fixture.coordinator.finishRecording()

        #expect(await provider.requests.isEmpty)
        if case .cancelled = fixture.coordinator.state {
            // Checkpoint cancelled before provider dispatch.
        } else {
            Issue.record("Expected checkpoint cancellation")
        }
    }

    @Test
    func appModelGateInvalidationCancelsReachableCoordinatorBeforeRemoteWork() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(provider: provider)
        try await fixture.coordinator.begin(intent: .compose)
        var cancellation: Task<Void, Never>?
        var setupPresented = false

        let allowed = AppModel.enforceAdaptiveScribeEntry(
            availability: .setupRequired,
            cancelActiveCoordinator: {
                cancellation = Task { @MainActor in
                    await fixture.coordinator.cancel()
                }
            },
            presentSetup: { setupPresented = true }
        )
        await cancellation?.value

        #expect(!allowed)
        #expect(setupPresented)
        if case .cancelled = fixture.coordinator.state {
            // Expected terminal cancellation before generation.
        } else {
            Issue.record("Expected coordinator cancellation")
        }
        #expect(await provider.requests.isEmpty)
        #expect(fixture.arbiter.activeKind == nil)
    }

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
            #expect(request?.input.userMessage.contains("Selected context") == true)
            #expect(request?.input.userMessage.contains("com.apple.TextEdit") == false)
        }
    }

    @Test
    func requestAppliesLocalShortcutButDoesNotMapLegacyStyleIntoEnvironment() async throws {
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
        #expect(request?.input.userMessage.contains("Expanded locally") == true)
        #expect(request?.input.userMessage.contains("Write a clear, concise draft") == true)
        #expect(request?.input.userMessage.contains("TextEdit profile") == false)
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
        let timedOutAttempt = fixture.coordinator.activeAttemptID

        await fixture.coordinator.retryGeneration()
        #expect(fixture.coordinator.reviewedResult?.text == "Recovered draft")
        #expect(fixture.coordinator.activeAttemptID != timedOutAttempt)
    }

    @Test
    func providerAuthorizationPrecedesSelectionCapture() async {
        let fixture = ScribeCoordinatorFixture(
            providerActionResolver: {
                throw ScribeProviderFailure(
                    phase: .generation,
                    category: .configurationInvalid,
                    retryDisposition: .reconnect
                )
            }
        )

        await #expect(throws: ScribeProviderFailure.self) {
            try await fixture.coordinator.begin(intent: .respond)
        }
        #expect(fixture.context.captureCount == 0)
    }

    @Test
    func actionResolvedAtBeginPinsRecipientAndProviderUntilTheSessionEnds() async throws {
        let firstProvider = CapturingScribeProvider(resultText: "First result")
        let replacementProvider = CapturingScribeProvider(resultText: "Replacement result")
        var selectedAction = ScribeProviderActionSnapshot(
            provider: firstProvider,
            destination: .deepSeek
        )
        let fixture = ScribeCoordinatorFixture(
            provider: firstProvider,
            providerActionResolver: { selectedAction }
        )

        try fixture.coordinator.prepareTarget()
        selectedAction = ScribeProviderActionSnapshot(
            provider: replacementProvider,
            destination: .advanced(
                origin: "https://replacement.example",
                disclosureVersion: ScribeProviderDisclosure.currentVersion
            )
        )
        try await fixture.coordinator.begin(intent: .respond)
        await fixture.coordinator.finishRecording()

        #expect(await firstProvider.requests.isEmpty)
        #expect(await replacementProvider.requests.count == 1)
        #expect(fixture.coordinator.reviewedResult?.text == "Replacement result")
    }

    @Test
    func targetChangeBeforeEgressMakesZeroProviderCalls() async throws {
        let provider = CapturingScribeProvider(resultText: "Must not run")
        let fixture = ScribeCoordinatorFixture(provider: provider)
        try await fixture.coordinator.begin(intent: .edit)
        fixture.context.shouldVerify = false

        await fixture.coordinator.finishRecording()

        #expect(await provider.requests.isEmpty)
        #expect(fixture.coordinator.failure == .context(.targetChanged))
        #expect(fixture.coordinator.literalTranscript == "Spoken request")
    }

    @Test
    func slowGenerationMovesToCalmSoftWaitBeforeTheHardDeadline() async throws {
        let fixture = ScribeCoordinatorFixture(
            providerResponses: [.delayedSuccess("Draft", .milliseconds(100))],
            generationTimeout: .seconds(1),
            generationSoftWait: .milliseconds(5)
        )
        try await fixture.coordinator.begin(intent: .compose)

        let finishing = Task { await fixture.coordinator.finishRecording() }
        for _ in 0..<1_000 {
            if case .generatingSlow = fixture.coordinator.state { break }
            await Task.yield()
        }

        if case .generatingSlow = fixture.coordinator.state {
            // Expected calm soft-wait state.
        } else {
            Issue.record("Expected generation to enter the soft-wait state")
        }
        await finishing.value
        #expect(fixture.coordinator.reviewedResult?.text == "Draft")
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
        #expect(fixture.coordinator.state == .insertionRecovery(
            ScribeResult(requestID: fixture.coordinator.activeRequestID!, text: "Draft")
        ))
    }

    @Test
    func requestCarriesImmutableResolvedEnvironmentAndProtectedLiterals() async throws {
        let casual = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .casual,
            definitionVersion: 1
        )
        let provider = CapturingScribeProvider(resultText: "Update `parseID`.")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            writingEnvironmentPreferences: { .valid([casual]) },
            engine: StubScribeTranscriptionEngine(
                text: "literal camel case parse capital I capital D end literal"
            )
        )

        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()

        let request = try #require(await provider.requests.first)
        #expect(request.input.userMessage.contains("Use relaxed, direct wording") == true)
        #expect(request.input.userMessage.contains("parseID") == true)
        #expect(request.input.userMessage.contains("Slack · Casual") == false)
    }

    @Test
    func malformedLiteralStopsBeforeProviderDispatch() async throws {
        let provider = CapturingScribeProvider(resultText: "Should not run")
        let fixture = ScribeCoordinatorFixture(
            provider: provider,
            engine: StubScribeTranscriptionEngine(text: "literal camel case parse I D")
        )

        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.failure == .literalRepair)
        #expect(await provider.requests.isEmpty)
    }

    @Test
    func coordinatorRejectsWrongRemoteAuthorityAndUnexpectedCancellation() async throws {
        let wrongIdentity = ScribeCoordinatorFixture(provider: WrongIdentityScribeProvider())
        try await wrongIdentity.coordinator.begin(intent: .compose)
        await wrongIdentity.coordinator.finishRecording()
        #expect(wrongIdentity.coordinator.failure == .provider(.invalidResult))

        let unexpectedCancellation = ScribeCoordinatorFixture(
            provider: UnexpectedCancellationScribeProvider()
        )
        try await unexpectedCancellation.coordinator.begin(intent: .compose)
        await unexpectedCancellation.coordinator.finishRecording()
        #expect(unexpectedCancellation.coordinator.providerFailure?.category == .transportUnavailable)
        #expect(unexpectedCancellation.coordinator.failure == .provider(.offline))
    }

    @Test
    func hardDeadlineReturnsEvenWhenProviderIgnoresCancellation() async throws {
        let fixture = ScribeCoordinatorFixture(
            provider: NonCooperativeScribeProvider(),
            generationTimeout: .milliseconds(10)
        )

        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()

        #expect(fixture.coordinator.failure == .provider(.timedOut))
        #expect(fixture.coordinator.state == .failed(
            requestID: fixture.coordinator.activeRequestID,
            error: .timedOut
        ))
    }

    @Test
    func confirmedInsertionClearsAllSessionContent() async throws {
        let fixture = ScribeCoordinatorFixture(providerResponses: [.success("Draft")])
        try await fixture.coordinator.begin(intent: .compose)
        await fixture.coordinator.finishRecording()
        try await fixture.coordinator.insertReviewedResult()

        #expect(fixture.coordinator.reviewedResult == nil)
        #expect(fixture.coordinator.literalTranscript == nil)
        #expect(fixture.coordinator.activeRequestID == nil)
        #expect(fixture.coordinator.resolvedEnvironment == nil)
        #expect(fixture.coordinator.exactLiterals.isEmpty)
    }

    @Test
    func fiftyInjectedProviderCyclesLeaveNoContentBearingSessionState() async throws {
        let fixture = ScribeCoordinatorFixture()

        for _ in 0..<50 {
            try await fixture.coordinator.begin(intent: .compose)
            await fixture.coordinator.finishRecording()
            try await fixture.coordinator.insertReviewedResult()

            #expect(fixture.coordinator.activeRequestID == nil)
            #expect(fixture.coordinator.reviewedResult == nil)
            #expect(fixture.coordinator.literalTranscript == nil)
            #expect(fixture.coordinator.exactLiterals.isEmpty)
        }

        #expect(fixture.context.clearedCaptureIDs.count == 50)
        #expect(fixture.arbiter.activeKind == nil)
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

    @Test
    func runtimeTargetPinsOnCaptureAndCancelClearsExactCaptureToken() async throws {
        let process = ApplicationProcessIdentity(
            processIdentifier: 42, bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"), incarnation: UUID()
        )
        let target = ApplicationTargetCapture(
            process: process, identityRevision: 1, captureRevision: 1,
            source: .scribeAccessibility, displayName: "Codex"
        )
        let fixture = ScribeCoordinatorFixture(applicationTarget: target)
        var pins: [UUID] = []
        var clears: [UUID] = []
        fixture.coordinator.onTargetPin = { capture, _ in pins.append(capture.id) }
        fixture.coordinator.onTargetClear = { clears.append($0) }

        try await fixture.coordinator.begin(intent: .compose)
        #expect(pins == [target.id])
        await fixture.coordinator.cancel()
        #expect(clears == [target.id])
    }

    @Test
    func panelCloseAwaitsCoordinatorCleanupBeforeReturningToIdle() async throws {
        let process = ApplicationProcessIdentity(
            processIdentifier: 43,
            bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            incarnation: UUID(),
            launchDate: Date(timeIntervalSince1970: 2)
        )
        let target = ApplicationTargetCapture(
            process: process,
            identityRevision: 1,
            captureRevision: 1,
            source: .scribeAccessibility,
            displayName: "Codex"
        )
        let fixture = ScribeCoordinatorFixture(applicationTarget: target)
        var clears: [UUID] = []
        fixture.coordinator.onTargetClear = { clears.append($0) }
        try await fixture.coordinator.begin(intent: .compose)

        await fixture.coordinator.dismissPanel()

        #expect(fixture.coordinator.state == .idle)
        #expect(clears == [target.id])
        #expect(fixture.context.clearedCaptureIDs.count == 1)
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
        providerActionResolver: (@MainActor () async throws -> ScribeProviderActionSnapshot)? = nil,
        selectedText: String = "Selected context",
        bundleIdentifier: String = "com.apple.TextEdit",
        recognitionSignature: TargetRecognitionSignature? = nil,
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        environmentRecognizer: WritingEnvironmentRecognizer = WritingEnvironmentRecognizer(),
        writingEnvironmentPreferences: @escaping () -> WritingEnvironmentPreferenceLoadResult = { .absent },
        providerDispatchAuthorization: @escaping @MainActor (ScribeProviderActionSnapshot) async -> Bool = { _ in true },
        engine: (any TranscriptionEngine)? = nil,
        generationTimeout: Duration = .seconds(5),
        generationSoftWait: Duration = .seconds(8),
        applicationTarget: ApplicationTargetCapture? = nil
    ) {
        context = StubScribeContextService(
            selectedText: selectedText,
            bundleIdentifier: bundleIdentifier,
            recognitionSignature: recognitionSignature,
            applicationTarget: applicationTarget
        )
        self.engine = engine ?? StubScribeTranscriptionEngine(text: "Spoken request")
        coordinator = ScribeCoordinator(
            audioCaptureService: audio,
            transcriptionEngine: self.engine,
            provider: provider ?? MockScribeProvider(responses: providerResponses),
            providerActionResolver: providerActionResolver,
            contextService: context,
            sessionArbiter: arbiter,
            personalizationStore: personalizationStore,
            environmentRecognizer: environmentRecognizer,
            writingEnvironmentPreferences: writingEnvironmentPreferences,
            providerDispatchAuthorization: providerDispatchAuthorization,
            generationTimeout: generationTimeout,
            generationSoftWait: generationSoftWait
        )
    }
}

@MainActor
private final class AdaptiveRuntimeFixture {
    let suite: String
    let defaults: UserDefaults
    let notificationCenter = NotificationCenter()
    let gateStore: AdaptiveScribeFeatureGateStore
    let monitor: AdaptiveScribeReaderMonitor

    init() throws {
        suite = "CadenceTests.AdaptiveRuntime.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let providerStore = ScribeProviderLibraryStore(defaults: defaults, key: "provider")
        let appStore = ApplicationConfigurationStore(defaults: defaults, key: "apps")
        let presetStore = ScribePresetCatalogStateStore(defaults: defaults, key: "presets")
        let settingsStore = SettingsPresentationStore(defaults: defaults, key: "settings")
        gateStore = AdaptiveScribeFeatureGateStore(defaults: defaults, key: "gates")
        let markers = AdaptiveScribeMigrationMarkerStore(defaults: defaults, keyPrefix: "markers")
        let configuration = try ScribeProviderLibraryConfiguration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            displayName: "OpenAI",
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: "gpt-test",
            catalogID: nil,
            disclosureVersion: 2,
            acceptedAt: Date(timeIntervalSince1970: 10),
            lastValidatedAt: Date(timeIntervalSince1970: 20),
            credentialReference: .init(rawValue: "credential"),
            isEnabled: true
        )
        try providerStore.save(.init(
            revision: 1,
            configurations: [configuration],
            activeConfigurationID: configuration.id
        ))
        try appStore.save(.init(revision: 1, configurations: []))
        try presetStore.save(.generalNeutral)
        try settingsStore.save(.init(selectedCategory: .general, isAdvancedExpanded: false))
        try gateStore.save(.allEnabled)
        for domain in AdaptiveScribeMigrationDomain.allCases { try markers.markComplete(domain) }
        monitor = AdaptiveScribeReaderMonitor(
            defaults: defaults,
            notificationCenter: notificationCenter,
            readerService: AdaptiveScribeLiveReaderService(
                providerStore: providerStore,
                applicationStore: appStore,
                presetStore: presetStore,
                settingsStore: settingsStore,
                featureGateStore: gateStore,
                markerStore: markers,
                polishedDictationRuntimeAvailable: true
            )
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
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
    private let bundleIdentifier: String
    private let recognitionSignature: TargetRecognitionSignature?
    private let applicationTarget: ApplicationTargetCapture
    var shouldVerify = true
    private(set) var clearedCaptureIDs: [UUID] = []
    private(set) var insertedTexts: [String] = []
    private(set) var discardPreparedTargetCount = 0
    private(set) var captureCount = 0
    private(set) var verificationCount = 0

    init(
        selectedText: String,
        bundleIdentifier: String,
        recognitionSignature: TargetRecognitionSignature?,
        applicationTarget: ApplicationTargetCapture? = nil
    ) {
        self.selectedText = selectedText
        self.bundleIdentifier = bundleIdentifier
        self.recognitionSignature = recognitionSignature
        self.applicationTarget = applicationTarget ?? ApplicationTargetCapture(
            process: ApplicationProcessIdentity(
                processIdentifier: 42,
                bundleIdentifier: bundleIdentifier,
                bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
                incarnation: UUID(),
                launchDate: Date(timeIntervalSince1970: 1)
            ),
            identityRevision: 1,
            captureRevision: 1,
            source: .scribeAccessibility,
            displayName: "Test"
        )
    }

    func prepareTarget() throws {}

    func capture(for intent: ScribeIntent) throws -> ScribeContextSnapshot {
        captureCount += 1
        return ScribeContextSnapshot(
            target: ScribeTargetIdentity(processIdentifier: 42, bundleIdentifier: bundleIdentifier),
            scope: intent.contextScope,
            selectedText: intent.requiresSelectedText ? selectedText : "",
            verificationToken: "window-a",
            recognitionSignature: recognitionSignature,
            applicationTarget: applicationTarget
        )
    }

    func verifyTarget(for capture: ScribeContextSnapshot) throws -> Bool {
        verificationCount += 1
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
    private(set) var requests: [ScribeProviderRequest] = []
    let resultText: String

    init(resultText: String) { self.resultText = resultText }

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        requests.append(request)
        return ScribeResult(requestID: request.id, text: resultText)
    }
}

private struct WrongIdentityScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        ScribeResult(requestID: UUID(), text: "Wrong authority")
    }
}

private struct UnexpectedCancellationScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        throw CancellationError()
    }
}

private struct NonCooperativeScribeProvider: ScribeProvider {
    let capabilities = ScribeProviderCapabilities.mock

    func generate(_ request: ScribeProviderRequest) async throws -> ScribeResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                continuation.resume(returning: ScribeResult(
                    requestID: request.id,
                    text: "Late ignored result"
                ))
            }
        }
    }
}
