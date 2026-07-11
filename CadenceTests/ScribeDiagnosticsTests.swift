import Foundation
import Testing
@testable import Cadence

struct ScribeDiagnosticsTests {
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
