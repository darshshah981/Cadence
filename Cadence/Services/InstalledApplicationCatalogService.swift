import AppKit
import Foundation
import UniformTypeIdentifiers

protocol InstalledApplicationFileSystem: Sendable {
    func canonicalURL(_ url: URL) async -> URL
    func children(of url: URL) async throws -> [URL]
    func metadata(at url: URL) async -> InstalledApplicationBundleMetadata?
}

protocol InstalledApplicationLifecycleSource: Sendable {
    func events() async -> AsyncStream<InstalledApplicationCatalogEvent>
    func stop() async
}

protocol InstalledApplicationRefreshDebouncing: Sendable {
    func wait() async throws
}

struct BoundedInstalledApplicationDebouncer: InstalledApplicationRefreshDebouncing {
    let duration: Duration

    init(duration: Duration = .milliseconds(250)) { self.duration = duration }

    func wait() async throws { try await Task.sleep(for: duration) }
}

struct SystemInstalledApplicationFileSystem: InstalledApplicationFileSystem, @unchecked Sendable {
    private let fileManager = FileManager.default

    func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func children(of url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
            options: [.skipsHiddenFiles]
        ).filter { child in
            if child.pathExtension.lowercased() == "app" { return true }
            return (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    func metadata(at url: URL) -> InstalledApplicationBundleMetadata? {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              !identifier.isEmpty,
              let executableURL = bundle.executableURL else { return nil }
        let applicationValues = try? url.resourceValues(forKeys: [.contentTypeKey])
        let canonicalExecutable = canonicalURL(executableURL)
        let executableValues = try? canonicalExecutable.resourceValues(forKeys: [
            .isRegularFileKey
        ])
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApplicationBundleMetadata(
            isApplicationBundle: applicationValues?.contentType?.conforms(to: .applicationBundle) == true,
            bundleIdentifier: identifier,
            displayName: displayName,
            executableURL: canonicalExecutable,
            executableExists: fileManager.fileExists(atPath: canonicalExecutable.path),
            executableIsRegularFile: executableValues?.isRegularFile == true,
            executableIsExecutable: fileManager.isExecutableFile(atPath: canonicalExecutable.path),
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            isUIElement: (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool) == true,
            isBackgroundOnly: (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) == true
        )
    }
}

protocol InstalledApplicationRunningSource: Sendable {
    @MainActor func snapshot() -> [InstalledApplicationDescriptor]
}

struct WorkspaceInstalledApplicationRunningSource: InstalledApplicationRunningSource {
    @MainActor
    func snapshot() -> [InstalledApplicationDescriptor] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard let url = application.bundleURL,
                  let identifier = application.bundleIdentifier else { return nil }
            return InstalledApplicationDescriptor(
                bundleURL: url,
                bundleIdentifier: identifier,
                displayName: application.localizedName ?? url.deletingPathExtension().lastPathComponent,
                version: nil,
                build: nil,
                isInstalled: true,
                isRunning: true
            )
        }
    }
}

@MainActor
final class WorkspaceInstalledApplicationLifecycleSource: InstalledApplicationLifecycleSource, @unchecked Sendable {
    private let stream: AsyncStream<InstalledApplicationCatalogEvent>
    private let continuation: AsyncStream<InstalledApplicationCatalogEvent>.Continuation
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var isStopped = false

    init(workspace: NSWorkspace = .shared) {
        let pair = AsyncStream.makeStream(of: InstalledApplicationCatalogEvent.self)
        stream = pair.stream
        continuation = pair.continuation
        let center = workspace.notificationCenter
        notificationCenter = center
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let event = Self.map(note) else { return }
                self?.continuation.yield(event)
            })
        }
    }

    func events() -> AsyncStream<InstalledApplicationCatalogEvent> { stream }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        continuation.finish()
    }

    nonisolated static func map(_ notification: Notification) -> InstalledApplicationCatalogEvent? {
        switch notification.name {
        case NSWorkspace.didLaunchApplicationNotification,
             NSWorkspace.didTerminateApplicationNotification:
            return .applicationsChanged
        case NSWorkspace.didMountNotification:
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return nil }
            return .mounted(root: url)
        case NSWorkspace.didUnmountNotification:
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return nil }
            return .unmounted(root: url)
        case NSWorkspace.didRenameVolumeNotification:
            guard let old = notification.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL,
                  let new = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return nil }
            return .volumeRelocated(oldRoot: old, newRoot: new)
        default:
            return nil
        }
    }
}

@MainActor
final class InstalledApplicationCatalogSnapshotStore {
    private(set) var snapshot: InstalledApplicationCatalogSnapshot = .empty
    var onPublish: ((InstalledApplicationCatalogSnapshot) -> Void)?
    func publish(_ snapshot: InstalledApplicationCatalogSnapshot) {
        self.snapshot = snapshot
        onPublish?(snapshot)
    }
}

actor InstalledApplicationCatalogService {
    static var standardRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    private let fileSystem: any InstalledApplicationFileSystem
    private let roots: [URL]
    private let cadenceBundleIdentifiers: Set<String>
    private let currentBundleURL: URL?
    private let snapshotStore: InstalledApplicationCatalogSnapshotStore
    private let debouncer: any InstalledApplicationRefreshDebouncing
    private let runningSource: any InstalledApplicationRunningSource
    private var generation = 0
    private var stopped = false
    private var runningApplications: [InstalledApplicationDescriptor] = []
    private var explicitURLs: Set<URL> = []
    private var rememberedURLs: Set<URL>
    private var lifecycleTask: Task<Void, Never>?
    private var initialRefreshTask: Task<Void, Never>?
    private var debouncedRefreshTask: Task<Void, Never>?
    private var lifecycleSource: (any InstalledApplicationLifecycleSource)?
    private var pendingRelocations: [(oldRoot: URL, newRoot: URL)] = []

    init(
        fileSystem: any InstalledApplicationFileSystem = SystemInstalledApplicationFileSystem(),
        roots: [URL] = InstalledApplicationCatalogService.standardRoots,
        cadenceBundleIdentifiers: Set<String>,
        currentBundleURL: URL?,
        snapshotStore: InstalledApplicationCatalogSnapshotStore,
        rememberedURLs: Set<URL> = [],
        debouncer: any InstalledApplicationRefreshDebouncing = BoundedInstalledApplicationDebouncer(),
        runningSource: any InstalledApplicationRunningSource = WorkspaceInstalledApplicationRunningSource()
    ) {
        self.fileSystem = fileSystem
        self.roots = roots
        self.cadenceBundleIdentifiers = cadenceBundleIdentifiers
        self.currentBundleURL = currentBundleURL?.standardizedFileURL
        self.snapshotStore = snapshotStore
        self.rememberedURLs = rememberedURLs
        self.debouncer = debouncer
        self.runningSource = runningSource
    }

    func start(lifecycleSource: any InstalledApplicationLifecycleSource) async {
        guard !stopped, lifecycleTask == nil else { return }
        self.lifecycleSource = lifecycleSource
        let events = await lifecycleSource.events()
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                guard !Task.isCancelled else { return }
                await self.schedule(event)
            }
        }
        initialRefreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func pageAppeared() async { await refresh() }

    func chooseApplication(at url: URL) async -> InstalledApplicationDescriptor? {
        guard let descriptor = await descriptor(at: url, isRunning: false) else {
            await refresh()
            return nil
        }
        explicitURLs.insert(descriptor.bundleURL)
        await refresh()
        return descriptor
    }

    func updateRememberedURLs(_ urls: Set<URL>) {
        rememberedURLs = urls
    }

    func refresh(
        runningApplications: [InstalledApplicationDescriptor]? = nil,
        explicitURLs: Set<URL>? = nil,
        rememberedURLs: Set<URL>? = nil
    ) async {
        guard !stopped else { return }
        if let runningApplications { self.runningApplications = runningApplications }
        else { self.runningApplications = await runningSource.snapshot() }
        if let explicitURLs { self.explicitURLs = explicitURLs }
        if let rememberedURLs { self.rememberedURLs = rememberedURLs }
        generation += 1
        let requestedGeneration = generation
        let running = self.runningApplications
        let explicit = self.explicitURLs
        let remembered = self.rememberedURLs

        var descriptors: [InstalledApplicationDescriptor] = []
        for root in roots {
            descriptors.append(contentsOf: await scan(root: root))
        }
        for url in explicit.union(remembered) {
            if let descriptor = await descriptor(at: url, isRunning: false) {
                descriptors.append(descriptor)
            }
        }
        for runningApplication in running {
            guard let canonical = await canonicalAllowedURL(runningApplication.bundleURL),
                  cadenceBundleIdentifiers.contains(runningApplication.bundleIdentifier) == false,
                  let descriptor = await descriptor(at: canonical, isRunning: true) else { continue }
            descriptors.append(descriptor)
        }
        let merged = Dictionary(grouping: descriptors, by: { $0.bundleURL.standardizedFileURL })
            .compactMap { _, copies -> InstalledApplicationDescriptor? in
                guard let first = copies.first else { return nil }
                return InstalledApplicationDescriptor(
                    bundleURL: first.bundleURL,
                    bundleIdentifier: first.bundleIdentifier,
                    displayName: first.displayName,
                    version: first.version,
                    build: first.build,
                    isInstalled: copies.contains(where: \.isInstalled),
                    isRunning: copies.contains(where: \.isRunning),
                    isUserFacing: copies.contains(where: \.isUserFacing)
                )
            }
            .sorted {
                let name = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return name == .orderedSame
                    ? $0.bundleURL.path < $1.bundleURL.path
                    : name == .orderedAscending
            }
        guard !stopped, generation == requestedGeneration else { return }
        await snapshotStore.publish(.init(generation: requestedGeneration, applications: merged))
    }

    func handle(_ event: InstalledApplicationCatalogEvent) async {
        guard !stopped else { return }
        if case let .volumeRelocated(oldRoot, newRoot) = event {
            explicitURLs = remap(explicitURLs, oldRoot: oldRoot, newRoot: newRoot)
            rememberedURLs = remap(rememberedURLs, oldRoot: oldRoot, newRoot: newRoot)
        }
        await refresh()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        generation += 1
        lifecycleTask?.cancel()
        lifecycleTask = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = nil
        pendingRelocations.removeAll()
        let source = lifecycleSource
        lifecycleSource = nil
        await source?.stop()
    }

    private func schedule(_ event: InstalledApplicationCatalogEvent) {
        generation += 1
        if case let .volumeRelocated(oldRoot, newRoot) = event {
            pendingRelocations.append((oldRoot, newRoot))
        }
        debouncedRefreshTask?.cancel()
        debouncedRefreshTask = Task { [weak self, debouncer] in
            do { try await debouncer.wait() } catch { return }
            guard !Task.isCancelled, let self else { return }
            await self.flushPendingEvents()
        }
    }

    private func flushPendingEvents() async {
        let relocations = pendingRelocations
        pendingRelocations.removeAll()
        for relocation in relocations {
            explicitURLs = remap(
                explicitURLs, oldRoot: relocation.oldRoot, newRoot: relocation.newRoot
            )
            rememberedURLs = remap(
                rememberedURLs, oldRoot: relocation.oldRoot, newRoot: relocation.newRoot
            )
        }
        await refresh()
    }

    private func scan(root: URL) async -> [InstalledApplicationDescriptor] {
        guard !Task.isCancelled else { return [] }
        let children = (try? await fileSystem.children(of: root)) ?? []
        var found: [InstalledApplicationDescriptor] = []
        for child in children {
            guard !Task.isCancelled else { return found }
            if child.pathExtension.lowercased() == "app" {
                if let descriptor = await descriptor(at: child, isRunning: false) {
                    found.append(descriptor)
                }
                continue
            }
            found.append(contentsOf: await scan(root: child))
        }
        return found
    }

    private func descriptor(at url: URL, isRunning: Bool) async -> InstalledApplicationDescriptor? {
        guard let canonical = await canonicalAllowedURL(url),
              canonical.pathExtension.lowercased() == "app",
              let metadata = await fileSystem.metadata(at: canonical),
              metadata.isApplicationBundle,
              let identifier = metadata.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty,
              identifier.utf8.count <= 255,
              !identifier.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !cadenceBundleIdentifiers.contains(identifier),
              !metadata.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.displayName.utf8.count <= 256,
              !metadata.displayName.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              metadata.executableExists,
              metadata.executableIsRegularFile,
              metadata.executableIsExecutable,
              let executableURL = metadata.executableURL else { return nil }
        let executable = await fileSystem.canonicalURL(executableURL).standardizedFileURL
        guard executable.isDescendant(of: canonical) else { return nil }
        return InstalledApplicationDescriptor(
            bundleURL: canonical,
            bundleIdentifier: identifier,
            displayName: metadata.displayName.precomposedStringWithCanonicalMapping,
            version: metadata.version,
            build: metadata.build,
            isInstalled: true,
            isRunning: isRunning,
            isUserFacing: !metadata.isUIElement && !metadata.isBackgroundOnly
        )
    }

    private func canonicalAllowedURL(_ url: URL) async -> URL? {
        guard url.isFileURL else { return nil }
        let canonical = await fileSystem.canonicalURL(url).standardizedFileURL
        if let currentBundleURL {
            let currentCanonical = await fileSystem.canonicalURL(currentBundleURL).standardizedFileURL
            if canonical == currentCanonical { return nil }
        }
        return canonical
    }

    private func remap(_ urls: Set<URL>, oldRoot: URL, newRoot: URL) -> Set<URL> {
        Set(urls.map { url in
            guard url.isDescendant(of: oldRoot) else { return url }
            let suffix = String(url.standardizedFileURL.path.dropFirst(oldRoot.standardizedFileURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return newRoot.appendingPathComponent(suffix)
        })
    }
}

private extension URL {
    func isDescendant(of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let components = standardizedFileURL.pathComponents
        return components.count > parentComponents.count
            && Array(components.prefix(parentComponents.count)) == parentComponents
    }
}
