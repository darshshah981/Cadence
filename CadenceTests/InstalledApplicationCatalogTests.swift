import AppKit
import Foundation
import Testing
@testable import Cadence

@MainActor
struct InstalledApplicationCatalogTests {
    @Test
    func standardRootsStopAtAppsValidateBundlesRejectCadenceAndRetainSameIDCopies() async throws {
        let fs = CatalogFileSystemFake()
        let apps = URL(fileURLWithPath: "/Applications")
        let slack = apps.appendingPathComponent("Slack.app")
        let nested = slack.appendingPathComponent("Contents/Accidental.app")
        let duplicate = apps.appendingPathComponent("Slack Copy.app")
        let cadence = apps.appendingPathComponent("Cadence.app")
        let invalid = apps.appendingPathComponent("Broken.app")
        await fs.setChildren([slack, duplicate, cadence, invalid], for: apps)
        await fs.setMetadata(.application(id: "com.tinyspeck.slackmacgap", name: "Slack"), for: slack)
        await fs.setMetadata(.application(id: "com.tinyspeck.slackmacgap", name: "Slack"), for: duplicate)
        await fs.setMetadata(.application(id: "com.darshshah.Cadence", name: "Cadence"), for: cadence)
        await fs.setMetadata(.invalidApplication(name: "Broken"), for: invalid)
        await fs.setChildren([nested], for: slack)
        let state = InstalledApplicationCatalogSnapshotStore()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs,
            roots: [apps],
            cadenceBundleIdentifiers: ["com.darshshah.Cadence", "com.darshshah.Cadence.debug"],
            currentBundleURL: cadence,
            snapshotStore: state
        )

        await service.refresh()

        #expect(state.snapshot.applications.map(\.bundleURL) == [duplicate, slack])
        #expect(await fs.childrenRequests.contains(slack) == false)
        #expect(state.snapshot.applications.allSatisfy { $0.bundleIdentifier == "com.tinyspeck.slackmacgap" })
    }

    @Test
    func explicitExternalAndRelocatedConfiguredAppsRefreshWithoutScanningVolumesRoot() async throws {
        let fs = CatalogFileSystemFake()
        let old = URL(fileURLWithPath: "/Volumes/Work/Apps/Cursor.app")
        let moved = URL(fileURLWithPath: "/Volumes/Work Renamed/Apps/Cursor.app")
        await fs.setMetadata(.application(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"), for: moved)
        let state = InstalledApplicationCatalogSnapshotStore()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs,
            roots: [],
            cadenceBundleIdentifiers: [],
            currentBundleURL: nil,
            snapshotStore: state,
            rememberedURLs: [old]
        )

        await service.handle(.volumeRelocated(
            oldRoot: URL(fileURLWithPath: "/Volumes/Work"),
            newRoot: URL(fileURLWithPath: "/Volumes/Work Renamed")
        ))

        #expect(state.snapshot.applications.map(\.bundleURL) == [moved])
        #expect(!(await fs.childrenRequests.contains(URL(fileURLWithPath: "/Volumes"))))
    }

    @Test
    func staleGenerationAndStoppedServiceCannotPublish() async throws {
        let fs = CatalogFileSystemFake()
        let root = URL(fileURLWithPath: "/Applications")
        let old = root.appendingPathComponent("Old.app")
        let fresh = root.appendingPathComponent("Fresh.app")
        await fs.setMetadata(.application(id: "example.old", name: "Old"), for: old)
        await fs.setMetadata(.application(id: "example.fresh", name: "Fresh"), for: fresh)
        let gate = CatalogScanGate()
        await fs.queueRootScan([old], gate: gate)
        await fs.queueRootScan([fresh], gate: nil)
        let state = InstalledApplicationCatalogSnapshotStore()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [root], cadenceBundleIdentifiers: [],
            currentBundleURL: nil, snapshotStore: state
        )
        let first = Task { await service.refresh() }
        await gate.waitUntilEntered()
        await service.refresh()
        await gate.release()
        await first.value
        #expect(state.snapshot.applications.map(\.bundleURL) == [fresh])

        await service.stop()
        await service.refresh(explicitURLs: [old])
        #expect(state.snapshot.applications.map(\.bundleURL) == [fresh])
    }

    @Test
    func rejectsWrongContentTypeMissingNonRegularNonExecutableAndEscapingExecutables() async throws {
        let fs = CatalogFileSystemFake()
        let root = URL(fileURLWithPath: "/Applications")
        let values = (0..<5).map { root.appendingPathComponent("Bad\($0).app") }
        await fs.setChildren(values, for: root)
        await fs.setMetadata(.init(
            isApplicationBundle: false, bundleIdentifier: "bad.type", displayName: "Bad",
            executableURL: values[0].appendingPathComponent("Contents/MacOS/App"),
            executableExists: true, executableIsRegularFile: true, executableIsExecutable: true,
            version: nil, build: nil
        ), for: values[0])
        await fs.setMetadata(.application(id: "bad.missing", name: "Bad", executableExists: false), for: values[1])
        await fs.setMetadata(.application(id: "bad.directory", name: "Bad", executableIsRegularFile: false), for: values[2])
        await fs.setMetadata(.application(id: "bad.mode", name: "Bad", executableIsExecutable: false), for: values[3])
        await fs.setMetadata(.application(
            id: "bad.escape", name: "Bad",
            executableURL: URL(fileURLWithPath: "/tmp/EscapedExecutable")
        ), for: values[4])
        let state = InstalledApplicationCatalogSnapshotStore()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [root], cadenceBundleIdentifiers: [], currentBundleURL: nil,
            snapshotStore: state, runningSource: EmptyRunningApplications()
        )

        await service.refresh()

        #expect(state.snapshot.applications.isEmpty)
    }

    @Test
    func workspaceNotificationsMapToCatalogEvents() {
        let volume = URL(fileURLWithPath: "/Volumes/Work")
        let old = URL(fileURLWithPath: "/Volumes/Old")
        #expect(WorkspaceInstalledApplicationLifecycleSource.map(Notification(
            name: NSWorkspace.didLaunchApplicationNotification
        )) == .applicationsChanged)
        #expect(WorkspaceInstalledApplicationLifecycleSource.map(Notification(
            name: NSWorkspace.didMountNotification,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: volume]
        )) == .mounted(root: volume))
        #expect(WorkspaceInstalledApplicationLifecycleSource.map(Notification(
            name: NSWorkspace.didRenameVolumeNotification,
            userInfo: [NSWorkspace.oldVolumeURLUserInfoKey: old, NSWorkspace.volumeURLUserInfoKey: volume]
        )) == .volumeRelocated(oldRoot: old, newRoot: volume))
    }

    @Test
    func lifecycleRegistersOnceDebouncesAndStopUnregistersOnceWithNoLatePublish() async throws {
        let fs = CatalogFileSystemFake()
        let state = InstalledApplicationCatalogSnapshotStore()
        let source = CatalogLifecycleFake()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [], cadenceBundleIdentifiers: [],
            currentBundleURL: nil, snapshotStore: state,
            debouncer: ImmediateInstalledApplicationDebouncer(),
            runningSource: EmptyRunningApplications()
        )
        await service.start(lifecycleSource: source)
        while state.snapshot.generation < 1 { await Task.yield() }
        await source.send(.mounted(root: URL(fileURLWithPath: "/Volumes/Work")))
        while state.snapshot.generation < 2 { await Task.yield() }
        let published = state.snapshot
        await service.stop()
        await service.stop()
        await source.send(.mounted(root: URL(fileURLWithPath: "/Volumes/Late")))
        for _ in 0..<20 { await Task.yield() }
        #expect(await source.stopCount == 1)
        #expect(state.snapshot == published)
    }

    @Test
    func startupConsumesLifecycleBeforeInitialScanCanPublishStaleResults() async throws {
        let fs = CatalogFileSystemFake()
        let root = URL(fileURLWithPath: "/Applications")
        let stale = root.appendingPathComponent("Stale.app")
        let fresh = root.appendingPathComponent("Fresh.app")
        await fs.setMetadata(.application(id: "example.stale", name: "Stale"), for: stale)
        await fs.setMetadata(.application(id: "example.fresh", name: "Fresh"), for: fresh)
        let gate = CatalogScanGate()
        await fs.queueRootScan([stale], gate: gate)
        await fs.queueRootScan([fresh], gate: nil)
        let state = InstalledApplicationCatalogSnapshotStore()
        let source = CatalogLifecycleFake()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [root], cadenceBundleIdentifiers: [], currentBundleURL: nil,
            snapshotStore: state, debouncer: ImmediateInstalledApplicationDebouncer(),
            runningSource: EmptyRunningApplications()
        )

        await service.start(lifecycleSource: source)
        await gate.waitUntilEntered()
        await source.send(.applicationsChanged)
        for _ in 0..<20 { await Task.yield() }
        await gate.release()
        while state.snapshot.generation < 3 { await Task.yield() }

        #expect(state.snapshot.applications.map(\.bundleURL) == [fresh])
        #expect(!state.snapshot.applications.contains(where: { $0.bundleURL == stale }))
        await service.stop()
    }

    @Test
    func lifecycleEventsInvalidateImmediatelyAndCoalesceAsASetBeforeOneRefresh() async throws {
        let fs = CatalogFileSystemFake()
        let firstOld = URL(fileURLWithPath: "/Volumes/A/One.app")
        let secondOld = URL(fileURLWithPath: "/Volumes/B/Two.app")
        let firstNew = URL(fileURLWithPath: "/Volumes/A2/One.app")
        let secondNew = URL(fileURLWithPath: "/Volumes/B2/Two.app")
        await fs.setMetadata(.application(id: "example.one", name: "One"), for: firstNew)
        await fs.setMetadata(.application(id: "example.two", name: "Two"), for: secondNew)
        let state = InstalledApplicationCatalogSnapshotStore()
        let source = CatalogLifecycleFake()
        let gate = CatalogDebounceGate()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [], cadenceBundleIdentifiers: [], currentBundleURL: nil,
            snapshotStore: state, rememberedURLs: [firstOld, secondOld],
            debouncer: ControlledCatalogDebouncer(gate: gate),
            runningSource: EmptyRunningApplications()
        )
        await service.start(lifecycleSource: source)
        while state.snapshot.generation < 1 { await Task.yield() }
        await source.send(.volumeRelocated(
            oldRoot: URL(fileURLWithPath: "/Volumes/A"), newRoot: URL(fileURLWithPath: "/Volumes/A2")
        ))
        await source.send(.volumeRelocated(
            oldRoot: URL(fileURLWithPath: "/Volumes/B"), newRoot: URL(fileURLWithPath: "/Volumes/B2")
        ))
        while await gate.waitCount < 1 { await Task.yield() }
        #expect(state.snapshot.generation == 1)
        await gate.release()
        while state.snapshot.generation < 4 { await Task.yield() }
        #expect(Set(state.snapshot.applications.map(\.bundleURL)) == [firstNew, secondNew])
        #expect(await gate.completionCount == 1)
        await service.stop()
    }

    @Test
    func chainedRelocationBurstComposesOldToMiddleToNewInOrder() async throws {
        let fs = CatalogFileSystemFake()
        let old = URL(fileURLWithPath: "/Volumes/Old/Apps/Tool.app")
        let final = URL(fileURLWithPath: "/Volumes/New/Apps/Tool.app")
        await fs.setMetadata(.application(id: "example.tool", name: "Tool"), for: final)
        let state = InstalledApplicationCatalogSnapshotStore()
        let source = CatalogLifecycleFake()
        let gate = CatalogDebounceGate()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [], cadenceBundleIdentifiers: [], currentBundleURL: nil,
            snapshotStore: state, rememberedURLs: [old],
            debouncer: ControlledCatalogDebouncer(gate: gate),
            runningSource: EmptyRunningApplications()
        )
        await service.start(lifecycleSource: source)
        while state.snapshot.generation < 1 { await Task.yield() }
        await source.send(.volumeRelocated(
            oldRoot: URL(fileURLWithPath: "/Volumes/Old"),
            newRoot: URL(fileURLWithPath: "/Volumes/Middle")
        ))
        await source.send(.volumeRelocated(
            oldRoot: URL(fileURLWithPath: "/Volumes/Middle"),
            newRoot: URL(fileURLWithPath: "/Volumes/New")
        ))
        while await gate.waitCount < 1 { await Task.yield() }
        await gate.release()
        while state.snapshot.generation < 4 { await Task.yield() }

        #expect(state.snapshot.applications.map(\.bundleURL) == [final])
        await service.stop()
    }

    @Test
    func rememberedExternalApplicationSurvivesRunningApplicationTermination() async throws {
        let fs = CatalogFileSystemFake()
        let external = URL(fileURLWithPath: "/Volumes/Tools/Codex.app")
        await fs.setMetadata(.application(id: "com.openai.codex", name: "Codex"), for: external)
        let state = InstalledApplicationCatalogSnapshotStore()
        let service = InstalledApplicationCatalogService(
            fileSystem: fs, roots: [], cadenceBundleIdentifiers: [], currentBundleURL: nil,
            snapshotStore: state, runningSource: EmptyRunningApplications()
        )
        let running = InstalledApplicationDescriptor(
            bundleURL: external, bundleIdentifier: "com.openai.codex", displayName: "Codex",
            version: nil, build: nil, isInstalled: true, isRunning: true
        )
        await service.refresh(runningApplications: [running])
        #expect(state.snapshot.applications.first?.isRunning == true)

        let suite = "CadenceTests.ExternalRebind.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationConfigurationStore(defaults: defaults, key: "apps")
        let original = try ApplicationConfiguration(
            application: ApplicationReference(
                bundleIdentifier: "com.openai.codex",
                lastKnownBundleURL: URL(fileURLWithPath: "/Volumes/Old/Codex.app"),
                lastKnownDisplayName: "Codex"
            ), isEnabled: true, familyID: .coding, presetSelection: .familyDefault,
            customGuidance: nil, revision: 1
        )
        try store.save(.init(revision: 1, configurations: [original]))
        let writer = ApplicationConfigurationWriter(store: store)
        _ = try await writer.rebind(
            configurationID: original.id,
            expectedLibraryRevision: 1,
            expectedConfigurationRevision: 1,
            expectedReferenceID: original.application.id,
            expectedOldURL: original.application.lastKnownBundleURL,
            snapshot: state.snapshot,
            newestSnapshot: { await MainActor.run { state.snapshot } },
            savedURLExists: { false },
            onCommittedRememberedURLs: { urls in
                await service.updateRememberedURLs(urls)
            }
        )
        await service.refresh(runningApplications: [])

        #expect(state.snapshot.applications.map(\.bundleURL) == [external])
        #expect(state.snapshot.applications.first?.isRunning == false)
    }
}

private struct EmptyRunningApplications: InstalledApplicationRunningSource {
    @MainActor func snapshot() -> [InstalledApplicationDescriptor] { [] }
}

private actor CatalogLifecycleFake: InstalledApplicationLifecycleSource {
    private let stream: AsyncStream<InstalledApplicationCatalogEvent>
    private let continuation: AsyncStream<InstalledApplicationCatalogEvent>.Continuation
    private(set) var stopCount = 0
    init() {
        let pair = AsyncStream.makeStream(of: InstalledApplicationCatalogEvent.self)
        stream = pair.stream
        continuation = pair.continuation
    }
    func events() -> AsyncStream<InstalledApplicationCatalogEvent> { stream }
    func send(_ event: InstalledApplicationCatalogEvent) { continuation.yield(event) }
    func stop() { stopCount += 1; continuation.finish() }
}

private actor CatalogDebounceGate {
    private(set) var waitCount = 0
    private(set) var completionCount = 0
    private var released = false
    func wait() async throws {
        waitCount += 1
        while !released {
            try Task.checkCancellation()
            await Task.yield()
        }
        completionCount += 1
    }
    func release() { released = true }
}

private struct ControlledCatalogDebouncer: InstalledApplicationRefreshDebouncing {
    let gate: CatalogDebounceGate
    func wait() async throws { try await gate.wait() }
}

private actor CatalogScanGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor CatalogFileSystemFake: InstalledApplicationFileSystem {
    struct RootScan { let values: [URL]; let gate: CatalogScanGate? }
    private var children: [URL: [URL]] = [:]
    private var metadata: [URL: InstalledApplicationBundleMetadata] = [:]
    private var scans: [RootScan] = []
    private(set) var childrenRequests: [URL] = []
    func setChildren(_ values: [URL], for url: URL) { children[url] = values }
    func setMetadata(_ value: InstalledApplicationBundleMetadata, for url: URL) {
        metadata[url] = InstalledApplicationBundleMetadata(
            isApplicationBundle: value.isApplicationBundle,
            bundleIdentifier: value.bundleIdentifier,
            displayName: value.displayName,
            executableURL: value.executableURL ?? url.appendingPathComponent("Contents/MacOS/App"),
            executableExists: value.executableExists,
            executableIsRegularFile: value.executableIsRegularFile,
            executableIsExecutable: value.executableIsExecutable,
            version: value.version,
            build: value.build
        )
    }
    func queueRootScan(_ values: [URL], gate: CatalogScanGate?) { scans.append(.init(values: values, gate: gate)) }
    func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL }
    func children(of url: URL) async throws -> [URL] {
        childrenRequests.append(url)
        if !scans.isEmpty {
            let scan = scans.removeFirst()
            if let gate = scan.gate { await gate.wait() }
            return scan.values
        }
        return children[url] ?? []
    }
    func metadata(at url: URL) -> InstalledApplicationBundleMetadata? { metadata[url] }
}
