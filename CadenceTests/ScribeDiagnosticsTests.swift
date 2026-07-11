import Foundation
import Testing
@testable import Cadence

struct ScribeDiagnosticsTests {
    @Test
    func newProviderDiagnosticsRoundTripWithoutModelOrRecipientData() throws {
        for provider in [ScribeDiagnosticProvider.openAIDirect, .openRouter] {
            let event = ScribeDiagnosticEvent(
                kind: .validationCompleted,
                phase: .validation,
                provider: provider,
                outcome: .success
            )
            let data = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(ScribeDiagnosticEvent.self, from: data) == event)
            let encoded = String(decoding: data, as: UTF8.self)
            #expect(!encoded.contains("gpt"))
            #expect(!encoded.contains("openrouter.ai"))
            #expect(!encoded.contains("api.openai.com"))
        }
    }

    @Test
    func providerDisclosuresNameExactRecipientAndMaterialRouting() {
        #expect(ScribeProviderDisclosure.openAIDirect.contains("https://api.openai.com"))
        #expect(ScribeProviderDisclosure.openAIDirect.contains("store to false"))
        #expect(ScribeProviderDisclosure.openAIDirect.contains("does not use server-side conversation state"))
        #expect(ScribeProviderDisclosure.openAIDirect.contains("not used for model training by default"))
        #expect(ScribeProviderDisclosure.openAIDirect.contains("abuse-monitoring data may be retained"))
        #expect(ScribeProviderDisclosure.openRouter.contains("https://openrouter.ai"))
        #expect(ScribeProviderDisclosure.openRouter.contains("Zero Data Retention"))
        #expect(ScribeProviderDisclosure.openRouter.contains("data collection to deny"))
        #expect(ScribeProviderDisclosure.openRouter.contains("retain limited router metadata"))
        for disclosure in [
            ScribeProviderDisclosure.openAIDirect,
            ScribeProviderDisclosure.openRouter
        ] {
            #expect(disclosure.contains("Processed dictation"))
            #expect(disclosure.contains("compiled preset"))
            #expect(disclosure.contains("optional normalized Custom guidance"))
            #expect(disclosure.contains("literal metadata"))
            #expect(disclosure.contains("exact protected terms and positions"))
            #expect(disclosure.contains("does not send app identity"))
            #expect(disclosure.contains("selected text"))
            #expect(disclosure.contains("clipboard contents"))
            #expect(disclosure.contains("window titles"))
            #expect(disclosure.contains("screen content"))
            #expect(disclosure.contains("files"))
            #expect(disclosure.contains("prior turns"))
            #expect(disclosure.contains("ambient context"))
        }
    }
    @Test
    func ringRoundsTimeAndPrunesByAgeAndCount() async {
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let storage = InMemoryDiagnosticsStorage()
        let service = ScribeDiagnosticsService(
            storage: storage,
            now: { now }
        )

        await service.replaceForTesting([
            Self.event(at: now.addingTimeInterval(-8 * 24 * 60 * 60))
        ])
        for _ in 0..<205 {
            await service.record(.init(
                kind: .generationCompleted,
                phase: .generation,
                provider: .deepSeek,
                outcome: .success,
                latency: .oneToFourSeconds,
                attempt: .thirdOrLater,
                retry: .none,
                appAdaptationEnabled: true,
                selectedTextIntent: false,
                fallbackUsed: false,
                lateResultSuppressed: false
            ))
        }

        let events = await service.events()
        #expect(events.count == 200)
        #expect(events.allSatisfy { Int($0.timestamp.timeIntervalSince1970) % 60 == 0 })
        #expect(events.allSatisfy { $0.timestamp >= now.addingTimeInterval(-7 * 24 * 60 * 60) })
    }

    @Test
    func persistedRingAndExportContainOnlyTypedSafeFields() async throws {
        let canaries = [
            "TRANSCRIPT_CANARY", "SELECTED_CANARY", "sk-secret-canary",
            "https://private.example/v1", "model-private", "com.private.App",
            "/Users/private/file", UUID().uuidString
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let storage = InMemoryDiagnosticsStorage()
        let service = ScribeDiagnosticsService(storage: storage, now: { now })
        await service.record(.init(
            kind: .generationCompleted,
            phase: .generation,
            provider: .advanced,
            outcome: .invalidResponse,
            latency: .eightToFifteenSeconds,
            attempt: .second,
            retry: .changeConfiguration,
            appAdaptationEnabled: true,
            selectedTextIntent: true,
            fallbackUsed: true,
            lateResultSuppressed: true
        ))
        await service.flush()

        let ringData = try #require(await storage.savedData)
        let exportData = try await ScribeDiagnosticsExportService.makeExport(
            events: service.events(),
            generatedAt: now,
            appVersion: "1.0",
            build: "100",
            macOSMajorVersion: 15,
            readiness: .ready,
            permissions: .init(microphone: true, accessibility: true, inputMonitoring: true),
            provider: .advanced,
            appAdaptationEnabled: true
        )
        for data in [ringData, exportData] {
            let text = String(decoding: data, as: UTF8.self)
            for canary in canaries { #expect(!text.contains(canary)) }
            #expect(!text.contains("requestID"))
            #expect(!text.contains("environment"))
        }
    }

    @Test
    func corruptOrFutureStorageLoadsEmptyAndClearRemovesMemoryAndDisk() async throws {
        let storage = InMemoryDiagnosticsStorage(savedData: Data("not-json".utf8))
        let service = ScribeDiagnosticsService(storage: storage)
        await service.load()
        #expect(await service.events().isEmpty)

        let future = ScribeDiagnosticRingEnvelope(schemaVersion: 999, events: [])
        await storage.setData(try JSONEncoder().encode(future))
        await service.load()
        #expect(await service.events().isEmpty)

        await service.record(.init(
            kind: .providerRemoved,
            phase: .readiness,
            provider: .none,
            outcome: .success
        ))
        await service.clear()
        #expect(await service.events().isEmpty)
        #expect(await storage.savedData == nil)
    }

    @Test
    func clearWaitsForAnInFlightSaveBeforeRemovingTheFile() async {
        let storage = BlockingDiagnosticsStorage()
        let service = ScribeDiagnosticsService(storage: storage)
        await service.record(.init(
            kind: .generationCompleted,
            phase: .generation,
            provider: .deepSeek,
            outcome: .success
        ))
        await storage.waitForSaveToStart()

        let clearTask = Task { await service.clear() }
        await Task.yield()
        await storage.releaseSave()
        await clearTask.value

        #expect(await service.events().isEmpty)
        #expect(await storage.savedData == nil)
    }

    private static func event(at date: Date) -> ScribeDiagnosticEvent {
        ScribeDiagnosticEvent(
            timestamp: date,
            kind: .generationStarted,
            phase: .generation,
            provider: .legacyLocal,
            outcome: .success
        )
    }
}

private actor InMemoryDiagnosticsStorage: ScribeDiagnosticsPersisting {
    private(set) var savedData: Data?

    init(savedData: Data? = nil) {
        self.savedData = savedData
    }

    func load() async throws -> Data? { savedData }
    func save(_ data: Data) async throws { savedData = data }
    func clear() async throws { savedData = nil }
    func setData(_ data: Data?) { savedData = data }
}

private actor BlockingDiagnosticsStorage: ScribeDiagnosticsPersisting {
    private(set) var savedData: Data?
    private var saveStarted = false
    private var saveContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> Data? { savedData }

    func save(_ data: Data) async throws {
        saveStarted = true
        await withCheckedContinuation { saveContinuation = $0 }
        savedData = data
    }

    func clear() async throws { savedData = nil }

    func waitForSaveToStart() async {
        while !saveStarted { await Task.yield() }
    }

    func releaseSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }
}
