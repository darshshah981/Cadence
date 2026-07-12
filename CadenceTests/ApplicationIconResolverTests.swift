import AppKit
import Testing
@testable import Cadence

@MainActor
struct ApplicationIconResolverTests {
    @Test
    func exactRunningThenBundleThenGenericResolutionOrder() async {
        let identity = Self.identity(pid: 7)
        let loader = ApplicationIconLoaderFake()
        loader.running = NSImage(size: NSSize(width: 32, height: 32))
        loader.bundle = NSImage(size: NSSize(width: 48, height: 48))
        let resolver = ApplicationIconResolver(loader: loader)
        #expect((await resolver.resolve(identity: identity)).source == .runningProcess)

        loader.running = nil
        resolver.invalidateAll()
        #expect((await resolver.resolve(identity: identity)).source == .bundle)

        loader.bundle = nil
        resolver.invalidateAll()
        #expect((await resolver.resolve(identity: identity)).source == .genericApplication)
    }

    @Test
    func processCacheIsExactIncarnationAndReturnsImageCopies() async {
        let loader = ApplicationIconLoaderFake()
        loader.running = NSImage(size: NSSize(width: 32, height: 32))
        let resolver = ApplicationIconResolver(loader: loader)
        let first = Self.identity(pid: 9)
        let second = ApplicationProcessIdentity(
            processIdentifier: first.processIdentifier,
            bundleIdentifier: first.bundleIdentifier,
            bundleURL: first.bundleURL,
            incarnation: UUID()
        )
        let a = await resolver.resolve(identity: first)
        let b = await resolver.resolve(identity: first)
        _ = await resolver.resolve(identity: second)

        #expect(a.image !== b.image)
        #expect(loader.runningRequests == [first, second])
    }

    @Test
    func pinnedPresentationIgnoresLiveSwitchAndStaleClearThenResumesLatestLive() async {
        let loader = ApplicationIconLoaderFake()
        let resolver = ApplicationIconResolver(loader: loader)
        let arbiter = ApplicationPresentationArbiter(resolver: resolver)
        var values: [HUDApplicationPresentation] = []
        arbiter.onChange = { values.append($0) }
        let cursor = Self.focused(Self.identity(pid: 11), name: "Cursor", revision: 1)
        let slack = Self.focused(Self.identity(pid: 12), name: "Slack", revision: 2)
        arbiter.updateLive(cursor)
        let capture = ApplicationTargetCapture(
            process: cursor.process, identityRevision: 1, captureRevision: 1, source: .dictation
        )
        arbiter.pin(capture, displayName: "Cursor")
        arbiter.updateLive(slack)
        arbiter.clearPin(UUID())
        #expect(values.last?.displayName == "Cursor")
        arbiter.clearPin(capture.id)
        #expect(values.last?.displayName == "Slack")
    }

    @Test
    func lateIconCompletionCannotOverwriteNewerLiveApplication() async {
        let cursor = Self.focused(Self.identity(pid: 21), name: "Cursor", revision: 1)
        let slack = Self.focused(Self.identity(pid: 22), name: "Slack", revision: 2)
        let loader = ControlledApplicationIconLoader(blockedIdentity: cursor.process)
        let resolver = ApplicationIconResolver(loader: loader)
        let arbiter = ApplicationPresentationArbiter(resolver: resolver)
        var values: [HUDApplicationPresentation] = []
        arbiter.onChange = { values.append($0) }

        arbiter.updateLive(cursor)
        await loader.waitUntilBlockedRequestStarts()
        arbiter.updateLive(slack)
        while values.last?.displayName != "Slack" || values.last?.icon == nil {
            await Task.yield()
        }
        loader.releaseBlockedRequest()
        for _ in 0..<20 { await Task.yield() }

        #expect(values.last?.displayName == "Slack")
        #expect(values.last?.identity == slack.process)
    }

    @Test
    func liveSwitchDoesNotCancelPinnedIconRequest() async {
        let cursor = Self.focused(Self.identity(pid: 23), name: "Cursor", revision: 1)
        let slack = Self.focused(Self.identity(pid: 24), name: "Slack", revision: 2)
        let loader = ControlledApplicationIconLoader(blockedIdentity: cursor.process)
        let arbiter = ApplicationPresentationArbiter(
            resolver: ApplicationIconResolver(loader: loader)
        )
        var values: [HUDApplicationPresentation] = []
        arbiter.onChange = { values.append($0) }
        let capture = ApplicationTargetCapture(
            process: cursor.process,
            identityRevision: 1,
            captureRevision: 1,
            source: .dictation,
            displayName: "Cursor"
        )

        arbiter.pin(capture, displayName: "Cursor")
        await loader.waitUntilBlockedRequestStarts()
        arbiter.updateLive(slack)
        loader.releaseBlockedRequest()
        while values.last?.displayName != "Cursor" || values.last?.icon == nil {
            await Task.yield()
        }

        #expect(values.last?.pinID == capture.id)
        #expect(values.last?.identity == cursor.process)
    }

    @Test
    func pidReuseWithDifferentLaunchDateFallsBackToBundleIcon() async {
        let currentLaunch = Date(timeIntervalSince1970: 20)
        let old = ApplicationProcessIdentity(
            processIdentifier: 30,
            bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/Codex.app"),
            incarnation: UUID(),
            launchDate: Date(timeIntervalSince1970: 10)
        )
        let loader = IncarnationCheckingIconLoader(currentLaunchDate: currentLaunch)
        let resolver = ApplicationIconResolver(loader: loader)

        let result = await resolver.resolve(identity: old)

        #expect(result.source == .bundle)
        #expect(loader.runningAccepted == false)
    }

    @Test
    func targetedBundleInvalidationLeavesUnrelatedProcessCacheWarm() async {
        let loader = ApplicationIconLoaderFake()
        loader.running = NSImage(size: NSSize(width: 32, height: 32))
        let resolver = ApplicationIconResolver(loader: loader)
        let cursor = Self.identity(pid: 31)
        let slack = Self.identity(pid: 32)
        _ = await resolver.resolve(identity: cursor)
        _ = await resolver.resolve(identity: slack)

        resolver.invalidate(bundleURLs: [cursor.bundleURL])
        _ = await resolver.resolve(identity: cursor)
        _ = await resolver.resolve(identity: slack)

        #expect(loader.runningRequests == [cursor, slack, cursor])
    }

    @Test
    func lifecycleProcessInvalidationDoesNotEvictBundleMetadataCache() async {
        let loader = ApplicationIconLoaderFake()
        loader.bundle = NSImage(size: NSSize(width: 32, height: 32))
        let resolver = ApplicationIconResolver(loader: loader)
        let identity = Self.identity(pid: 37)
        _ = await resolver.resolve(identity: identity)

        resolver.invalidate(identity: identity)
        _ = await resolver.resolve(identity: identity)

        #expect(loader.bundleRequests == [identity.bundleURL])
    }

    @Test
    func nilDisplayNameUsesUnavailablePresentationWithoutBundleIdentifierLabel() {
        let resolver = ApplicationIconResolver(loader: ApplicationIconLoaderFake())
        let arbiter = ApplicationPresentationArbiter(resolver: resolver)
        var value = HUDApplicationPresentation.cadence
        arbiter.onChange = { value = $0 }

        arbiter.updateLive(Self.focused(Self.identity(pid: 33), name: nil, revision: 1))

        #expect(value.kind == .unavailableApplication)
        #expect(value.displayName == "Application unavailable")
        #expect(!value.displayName.contains("com.openai"))
    }

    @Test
    func exactPinnedTerminationImmediatelyPublishesUnavailableAndKeepsPinToken() {
        let identity = Self.identity(pid: 35)
        let capture = ApplicationTargetCapture(
            process: identity,
            identityRevision: 1,
            captureRevision: 1,
            source: .dictation,
            displayName: "Cursor"
        )
        let arbiter = ApplicationPresentationArbiter(
            resolver: ApplicationIconResolver(loader: ApplicationIconLoaderFake())
        )
        var value = HUDApplicationPresentation.cadence
        arbiter.onChange = { value = $0 }
        arbiter.pin(capture, displayName: "Cursor")

        arbiter.markTerminated(
            identity: identity,
            processIdentifier: identity.processIdentifier,
            bundleURL: identity.bundleURL,
            launchDate: identity.launchDate
        )

        #expect(value.kind == .unavailableApplication)
        #expect(value.pinID == capture.id)
        #expect(value.icon == nil)
    }

    @Test
    func delayedOldIncarnationTerminationCannotInvalidateReusedPIDPin() {
        let current = Self.identity(pid: 36)
        let oldLaunch = Date(timeIntervalSince1970: 1)
        let capture = ApplicationTargetCapture(
            process: current,
            identityRevision: 1,
            captureRevision: 1,
            source: .dictation,
            displayName: "Cursor"
        )
        let arbiter = ApplicationPresentationArbiter(
            resolver: ApplicationIconResolver(loader: ApplicationIconLoaderFake())
        )
        var value = HUDApplicationPresentation.cadence
        arbiter.onChange = { value = $0 }
        arbiter.pin(capture, displayName: "Cursor")

        arbiter.markTerminated(
            identity: nil,
            processIdentifier: current.processIdentifier,
            bundleURL: current.bundleURL,
            launchDate: oldLaunch
        )

        #expect(value.kind == .knownApplication)
        #expect(value.pinID == capture.id)
    }

    @Test
    func resizingNeverMutatesLoaderOwnedImage() async {
        let original = NSImage(size: NSSize(width: 64, height: 48))
        let loader = ApplicationIconLoaderFake()
        loader.running = original
        let resolver = ApplicationIconResolver(loader: loader)

        let result = await resolver.resolve(identity: Self.identity(pid: 34), pointSize: 18)

        #expect(original.size == NSSize(width: 64, height: 48))
        #expect(result.image.size == NSSize(width: 18, height: 18))
        #expect(result.image !== original)
    }

    @Test
    func catalogDiffInvalidatesOnlyAddedRemovedOrChangedURLs() {
        let unchanged = Self.descriptor(pid: 40, version: "1")
        let changedOld = Self.descriptor(pid: 41, version: "1")
        let changedNew = Self.descriptor(pid: 41, version: "2")
        let added = Self.descriptor(pid: 42, version: "1")
        let previous = InstalledApplicationCatalogSnapshot(
            generation: 1, applications: [unchanged, changedOld]
        )
        let next = InstalledApplicationCatalogSnapshot(
            generation: 2, applications: [unchanged, changedNew, added]
        )

        let affected = InstalledApplicationIconInvalidation.affectedBundleURLs(
            previous: previous, next: next
        )

        #expect(affected == [changedOld.bundleURL, added.bundleURL])
    }

    private static func identity(pid: Int32) -> ApplicationProcessIdentity {
        .init(
            processIdentifier: pid, bundleIdentifier: "com.openai.codex",
            bundleURL: URL(fileURLWithPath: "/Applications/App\(pid).app"),
            incarnation: UUID(), launchDate: Date(timeIntervalSince1970: TimeInterval(pid))
        )
    }

    private static func focused(
        _ process: ApplicationProcessIdentity,
        name: String?,
        revision: Int
    ) -> FocusedApplicationIdentity {
        .init(
            process: process, displayName: name, identityRevision: revision,
            presentationRevision: revision, observedAt: Date()
        )
    }

    private static func descriptor(pid: Int32, version: String) -> InstalledApplicationDescriptor {
        .init(
            bundleURL: identity(pid: pid).bundleURL,
            bundleIdentifier: "app.\(pid)",
            displayName: "App \(pid)",
            version: version,
            build: "1",
            isInstalled: true,
            isRunning: false
        )
    }
}

@MainActor
private final class ApplicationIconLoaderFake: ApplicationIconLoading {
    var running: NSImage?
    var bundle: NSImage?
    private(set) var runningRequests: [ApplicationProcessIdentity] = []
    private(set) var bundleRequests: [URL] = []
    func runningIcon(for identity: ApplicationProcessIdentity) async -> NSImage? {
        runningRequests.append(identity)
        return running
    }
    func bundleIcon(at url: URL) async -> NSImage? {
        bundleRequests.append(url)
        return bundle
    }
}

@MainActor
private final class ControlledApplicationIconLoader: ApplicationIconLoading {
    let blockedIdentity: ApplicationProcessIdentity
    private var blockedRequestStarted = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    init(blockedIdentity: ApplicationProcessIdentity) {
        self.blockedIdentity = blockedIdentity
    }

    func runningIcon(for identity: ApplicationProcessIdentity) async -> NSImage? {
        if identity == blockedIdentity {
            blockedRequestStarted = true
            await withCheckedContinuation { blockedContinuation = $0 }
        }
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    func bundleIcon(at url: URL) async -> NSImage? { nil }

    func waitUntilBlockedRequestStarts() async {
        while !blockedRequestStarted { await Task.yield() }
    }

    func releaseBlockedRequest() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

@MainActor
private final class IncarnationCheckingIconLoader: ApplicationIconLoading {
    let currentLaunchDate: Date
    private(set) var runningAccepted = false

    init(currentLaunchDate: Date) { self.currentLaunchDate = currentLaunchDate }

    func runningIcon(for identity: ApplicationProcessIdentity) async -> NSImage? {
        guard identity.launchDate == currentLaunchDate else { return nil }
        runningAccepted = true
        return NSImage(size: NSSize(width: 32, height: 32))
    }

    func bundleIcon(at url: URL) async -> NSImage? {
        NSImage(size: NSSize(width: 32, height: 32))
    }
}
