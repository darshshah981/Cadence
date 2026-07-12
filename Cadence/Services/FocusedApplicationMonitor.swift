import AppKit
import Foundation

protocol FocusedApplicationSource: AnyObject, Sendable {
    @MainActor func events() -> AsyncStream<FocusedApplicationEvent>
    @MainActor func frontmostSample() async -> FocusedApplicationSample?
    @MainActor func activate(_ identity: ApplicationProcessIdentity) -> Bool
    @MainActor func stop()
}

@MainActor
final class WorkspaceFocusedApplicationSource: FocusedApplicationSource, @unchecked Sendable {
    private let workspace: NSWorkspace
    private let center: NotificationCenter
    private let stream: AsyncStream<FocusedApplicationEvent>
    private let continuation: AsyncStream<FocusedApplicationEvent>.Continuation
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        center = workspace.notificationCenter
        let pair = AsyncStream.makeStream(of: FocusedApplicationEvent.self)
        stream = pair.stream
        continuation = pair.continuation
        observe(NSWorkspace.didActivateApplicationNotification) { _ in .activated }
        observe(NSWorkspace.didLaunchApplicationNotification) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let sample = Self.sample(app) else { return nil }
            return .launched(sample)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return nil
            }
            return .terminated(
                processIdentifier: app.processIdentifier,
                bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath(),
                launchDate: app.launchDate
            )
        }
        observe(NSWorkspace.didWakeNotification) { _ in .woke }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { _ in .sessionChanged }
    }

    func events() -> AsyncStream<FocusedApplicationEvent> { stream }

    func frontmostSample() -> FocusedApplicationSample? {
        workspace.frontmostApplication.flatMap(Self.sample)
    }

    func activate(_ identity: ApplicationProcessIdentity) -> Bool {
        guard let application = workspace.runningApplications.first(where: {
            $0.processIdentifier == identity.processIdentifier
                && $0.bundleIdentifier == identity.bundleIdentifier
                && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == identity.bundleURL
        }) else { return false }
        return application.activate()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        observers.forEach(center.removeObserver)
        observers.removeAll()
        continuation.finish()
    }

    private func observe(
        _ name: Notification.Name,
        map: @escaping @MainActor (Notification) -> FocusedApplicationEvent?
    ) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let event = map(note) else { return }
                self?.continuation.yield(event)
            }
        })
    }

    private static func sample(_ application: NSRunningApplication) -> FocusedApplicationSample? {
        guard let bundleIdentifier = application.bundleIdentifier,
              let bundleURL = application.bundleURL else { return nil }
        return FocusedApplicationSample(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL.standardizedFileURL.resolvingSymlinksInPath(),
            displayName: application.localizedName,
            launchDate: application.launchDate
        )
    }
}

@MainActor
final class FocusedApplicationMonitor {
    private struct ProcessKey: Hashable {
        let processIdentifier: Int32
        let bundleIdentifier: String
        let bundleURL: URL
    }

    private struct IncarnationRecord {
        let launchDate: Date?
        let id: UUID
    }

    private let source: any FocusedApplicationSource
    private let cadenceBundleIdentifiers: Set<String>
    private var eventTask: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var incarnations: [ProcessKey: IncarnationRecord] = [:]
    private(set) var currentExternal: FocusedApplicationIdentity?
    private(set) var history: [FocusedApplicationIdentity] = []
    private(set) var generation = 0
    private(set) var identityRevision = 0
    private(set) var presentationRevision = 0
    private(set) var isCurrentAuthoritative = false
    var onChange: ((FocusedApplicationIdentity?) -> Void)?
    var onLaunch: ((Int32, URL) -> Void)?
    var onTermination: ((ApplicationProcessIdentity?, Int32, URL?, Date?) -> Void)?

    init(
        source: any FocusedApplicationSource,
        cadenceBundleIdentifiers: Set<String>
    ) {
        self.source = source
        self.cadenceBundleIdentifiers = cadenceBundleIdentifiers
    }

    func start() {
        guard eventTask == nil else { return }
        let events = source.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
        requestResample()
    }

    func stop() {
        generation += 1
        eventTask?.cancel()
        eventTask = nil
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks.removeAll()
        source.stop()
    }

    func captureTarget(source captureSource: ApplicationTargetCapture.Source) async throws -> ApplicationTargetCapture {
        generation += 1
        let requestedGeneration = generation
        let candidate = await source.frontmostSample()
        let confirmation = await source.frontmostSample()
        guard Self.sameRuntimeProcess(candidate, confirmation) else {
            throw ApplicationTargetAuthorityError.targetChanged
        }
        apply(confirmation, requestedGeneration: requestedGeneration)
        guard isCurrentAuthoritative, let currentExternal else {
            throw ApplicationTargetAuthorityError.noExternalTarget
        }
        return ApplicationTargetCapture(
            process: currentExternal.process,
            identityRevision: currentExternal.identityRevision,
            captureRevision: presentationRevision,
            source: captureSource,
            displayName: currentExternal.displayName
        )
    }

    func verify(_ capture: ApplicationTargetCapture) async throws {
        generation += 1
        let requestedGeneration = generation
        let sample = await source.frontmostSample()
        apply(sample, requestedGeneration: requestedGeneration)
        guard isCurrentAuthoritative, currentExternal?.process == capture.process else {
            throw ApplicationTargetAuthorityError.targetChanged
        }
    }

    func exactIdentity(processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationProcessIdentity? {
        guard isCurrentAuthoritative,
              let bundleIdentifier,
              let currentExternal,
              currentExternal.process.processIdentifier == processIdentifier,
              currentExternal.process.bundleIdentifier == bundleIdentifier else { return nil }
        return currentExternal.process
    }

    func activateMostRecentValidatedExternal() -> Bool {
        guard let candidate = history.first else { return false }
        return source.activate(candidate.process)
    }

    func requestResample() {
        generation += 1
        let requestedGeneration = generation
        let taskID = UUID()
        refreshTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            let sample = await self.source.frontmostSample()
            guard !Task.isCancelled else { return }
            self.apply(sample, requestedGeneration: requestedGeneration)
            self.refreshTasks.removeValue(forKey: taskID)
        }
    }

    private func handle(_ event: FocusedApplicationEvent) {
        generation += 1
        isCurrentAuthoritative = false
        switch event {
        case let .launched(sample):
            incarnations.removeValue(forKey: key(for: sample))
            onLaunch?(sample.processIdentifier, sample.bundleURL.standardizedFileURL.resolvingSymlinksInPath())
        case let .terminated(processIdentifier, bundleIdentifier, bundleURL, launchDate):
            let canonical = bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
            let matching = ([currentExternal].compactMap { $0 } + history).first {
                Self.matchesTermination(
                    $0.process,
                    processIdentifier: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    bundleURL: canonical,
                    launchDate: launchDate
                )
            }?.process
            incarnations = incarnations.filter { key, record in
                guard key.processIdentifier == processIdentifier else { return true }
                if let bundleIdentifier, key.bundleIdentifier != bundleIdentifier { return true }
                if let canonical, key.bundleURL != canonical { return true }
                if let launchDate, record.launchDate != launchDate { return true }
                return false
            }
            if let currentExternal, Self.matchesTermination(
                currentExternal.process,
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundleURL: canonical,
                launchDate: launchDate
            ) {
                publish(nil)
            }
            onTermination?(matching, processIdentifier, canonical, launchDate)
        case .activated, .woke, .sessionChanged:
            break
        }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.requestResample()
        }
    }

    private func apply(_ sample: FocusedApplicationSample?, requestedGeneration: Int) {
        guard requestedGeneration == generation else { return }
        guard let sample,
              !cadenceBundleIdentifiers.contains(sample.bundleIdentifier) else {
            publish(nil)
            return
        }
        let key = key(for: sample)
        let incarnation: UUID
        if let existing = incarnations[key], existing.launchDate == sample.launchDate {
            incarnation = existing.id
        } else {
            incarnation = UUID()
            incarnations[key] = IncarnationRecord(launchDate: sample.launchDate, id: incarnation)
        }
        let process = ApplicationProcessIdentity(
                processIdentifier: sample.processIdentifier,
                bundleIdentifier: sample.bundleIdentifier,
                bundleURL: key.bundleURL,
                incarnation: incarnation,
                launchDate: sample.launchDate
            )
        if let currentExternal,
           currentExternal.process == process,
           currentExternal.displayName == sample.displayName {
            isCurrentAuthoritative = true
            return
        }
        identityRevision += 1
        presentationRevision += 1
        let identity = FocusedApplicationIdentity(
            process: process,
            displayName: sample.displayName,
            identityRevision: identityRevision,
            presentationRevision: presentationRevision,
            observedAt: Date()
        )
        isCurrentAuthoritative = true
        publish(identity)
    }

    private func publish(_ identity: FocusedApplicationIdentity?) {
        if currentExternal == identity { return }
        currentExternal = identity
        if identity == nil { isCurrentAuthoritative = false }
        presentationRevision += 1
        if let identity {
            history.removeAll { $0.process == identity.process }
            history.insert(identity, at: 0)
            if history.count > 16 { history.removeLast(history.count - 16) }
        }
        onChange?(identity)
    }

    private func key(for sample: FocusedApplicationSample) -> ProcessKey {
        ProcessKey(
            processIdentifier: sample.processIdentifier,
            bundleIdentifier: sample.bundleIdentifier,
            bundleURL: sample.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    private static func sameRuntimeProcess(
        _ lhs: FocusedApplicationSample?,
        _ rhs: FocusedApplicationSample?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.processIdentifier == rhs.processIdentifier
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
                == rhs.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            && lhs.launchDate == rhs.launchDate
    }

    private static func matchesTermination(
        _ identity: ApplicationProcessIdentity,
        processIdentifier: Int32,
        bundleIdentifier: String?,
        bundleURL: URL?,
        launchDate: Date?
    ) -> Bool {
        guard identity.processIdentifier == processIdentifier else { return false }
        if let bundleIdentifier, identity.bundleIdentifier != bundleIdentifier { return false }
        if let bundleURL, identity.bundleURL != bundleURL { return false }
        if let launchDate, identity.launchDate != launchDate { return false }
        return true
    }
}

@MainActor
protocol ApplicationTargetAuthorizing: AnyObject {
    func capture(source: ApplicationTargetCapture.Source) async throws -> ApplicationTargetCapture
    func verify(_ capture: ApplicationTargetCapture) async throws
    func enrich(processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationProcessIdentity?
    func enrichCapture(id: UUID, processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationTargetCapture?
    func matchesCurrent(_ identity: ApplicationProcessIdentity) -> Bool
}

@MainActor
final class ApplicationTargetAuthority: ApplicationTargetAuthorizing {
    private let monitor: FocusedApplicationMonitor

    init(monitor: FocusedApplicationMonitor) { self.monitor = monitor }

    func capture(source: ApplicationTargetCapture.Source) async throws -> ApplicationTargetCapture {
        try await monitor.captureTarget(source: source)
    }

    func verify(_ capture: ApplicationTargetCapture) async throws {
        try await monitor.verify(capture)
    }

    func enrich(processIdentifier: Int32, bundleIdentifier: String?) -> ApplicationProcessIdentity? {
        monitor.exactIdentity(processIdentifier: processIdentifier, bundleIdentifier: bundleIdentifier)
    }

    func enrichCapture(
        id: UUID,
        processIdentifier: Int32,
        bundleIdentifier: String?
    ) -> ApplicationTargetCapture? {
        guard monitor.isCurrentAuthoritative,
              let current = monitor.currentExternal,
              current.process.processIdentifier == processIdentifier,
              current.process.bundleIdentifier == bundleIdentifier else { return nil }
        return ApplicationTargetCapture(
            id: id,
            process: current.process,
            identityRevision: current.identityRevision,
            captureRevision: current.presentationRevision,
            source: .scribeAccessibility,
            displayName: current.displayName
        )
    }

    func matchesCurrent(_ identity: ApplicationProcessIdentity) -> Bool {
        monitor.isCurrentAuthoritative && monitor.currentExternal?.process == identity
    }
}
