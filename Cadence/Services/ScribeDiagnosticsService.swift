import Foundation

protocol ScribeDiagnosticsPersisting: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
    func clear() async throws
}

actor FileScribeDiagnosticsStorage: ScribeDiagnosticsPersisting {
    private let fileURL: URL

    init(fileURL: URL = FileScribeDiagnosticsStorage.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() async throws -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ data: Data) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() async throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("ScribeDiagnostics", isDirectory: true)
            .appendingPathComponent("events.json", isDirectory: false)
    }
}

actor ScribeDiagnosticsService {
    static let maximumEventCount = 200
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    private let storage: any ScribeDiagnosticsPersisting
    private let now: @Sendable () -> Date
    private var ring: [ScribeDiagnosticEvent] = []
    private var pendingWrite: Task<Void, Never>?
    private var mutationRevision = 0

    init(
        storage: any ScribeDiagnosticsPersisting = FileScribeDiagnosticsStorage(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.storage = storage
        self.now = now
    }

    func load() async {
        let revisionBeforeLoad = mutationRevision
        let loadedEvents: [ScribeDiagnosticEvent]
        if let data = try? await storage.load(),
           let envelope = try? JSONDecoder().decode(ScribeDiagnosticRingEnvelope.self, from: data),
           envelope.schemaVersion == ScribeDiagnosticRingEnvelope.currentSchemaVersion {
            loadedEvents = envelope.events
        } else {
            loadedEvents = []
        }
        ring = revisionBeforeLoad == mutationRevision ? loadedEvents : loadedEvents + ring
        prune(referenceDate: now())
    }

    func record(_ event: ScribeDiagnosticEvent) {
        let referenceDate = now()
        ring.append(event.timestamped(Self.roundedToMinute(referenceDate)))
        mutationRevision += 1
        prune(referenceDate: referenceDate)
        scheduleWrite()
    }

    func events() -> [ScribeDiagnosticEvent] {
        prune(referenceDate: now())
        return ring
    }

    func clear() async {
        let previousWrite = pendingWrite
        pendingWrite = nil
        previousWrite?.cancel()
        ring = []
        mutationRevision += 1
        await previousWrite?.value
        try? await storage.clear()
        if !ring.isEmpty { scheduleWrite() }
    }

    func flush() async {
        let previousWrite = pendingWrite
        pendingWrite = nil
        previousWrite?.cancel()
        await previousWrite?.value
        let data = encodedRing()
        if let data { try? await storage.save(data) }
        pendingWrite = nil
    }

    func replaceForTesting(_ events: [ScribeDiagnosticEvent]) {
        ring = events
        mutationRevision += 1
    }

    private func prune(referenceDate: Date) {
        let oldest = referenceDate.addingTimeInterval(-Self.maximumAge)
        ring.removeAll { $0.timestamp < oldest }
        if ring.count > Self.maximumEventCount {
            ring.removeFirst(ring.count - Self.maximumEventCount)
        }
    }

    private func scheduleWrite() {
        guard let data = encodedRing() else { return }
        let previousWrite = pendingWrite
        previousWrite?.cancel()
        pendingWrite = Task { [storage] in
            await previousWrite?.value
            guard !Task.isCancelled else { return }
            try? await storage.save(data)
        }
    }

    private func encodedRing() -> Data? {
        try? JSONEncoder().encode(ScribeDiagnosticRingEnvelope(events: ring))
    }

    static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }
}
