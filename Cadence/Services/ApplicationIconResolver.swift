import AppKit
import Foundation

enum InstalledApplicationIconInvalidation {
    static func affectedBundleURLs(
        previous: InstalledApplicationCatalogSnapshot,
        next: InstalledApplicationCatalogSnapshot
    ) -> Set<URL> {
        let old = previous.applications.reduce(into: [URL: InstalledApplicationDescriptor]()) {
            $0[$1.bundleURL.standardizedFileURL.resolvingSymlinksInPath()] = $1
        }
        let new = next.applications.reduce(into: [URL: InstalledApplicationDescriptor]()) {
            $0[$1.bundleURL.standardizedFileURL.resolvingSymlinksInPath()] = $1
        }
        return Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
    }
}

enum ApplicationIconSource: Equatable, Sendable {
    case runningProcess
    case bundle
    case genericApplication
}

@MainActor
struct ResolvedApplicationIcon {
    let image: NSImage
    let source: ApplicationIconSource
}

@MainActor
protocol ApplicationIconLoading: AnyObject {
    func runningIcon(for identity: ApplicationProcessIdentity) async -> NSImage?
    func bundleIcon(at url: URL) async -> NSImage?
}

@MainActor
final class WorkspaceApplicationIconLoader: ApplicationIconLoading {
    func runningIcon(for identity: ApplicationProcessIdentity) -> NSImage? {
        guard let launchDate = identity.launchDate,
              let app = NSRunningApplication(processIdentifier: identity.processIdentifier),
              app.bundleIdentifier == identity.bundleIdentifier,
              app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == identity.bundleURL,
              app.launchDate == launchDate else { return nil }
        return app.icon?.copy() as? NSImage
    }

    func bundleIcon(at url: URL) -> NSImage? {
        NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
    }
}

@MainActor
final class ApplicationIconResolver {
    private struct ProcessCacheKey: Hashable {
        let identity: ApplicationProcessIdentity
        let scale: Int
    }

    private struct BundleCacheKey: Hashable {
        let url: URL
        let modificationDate: Date?
        let fileSize: Int?
        let version: String?
        let build: String?
        let scale: Int
    }

    private let loader: any ApplicationIconLoading
    private var processCache: [ProcessCacheKey: ResolvedApplicationIcon] = [:]
    private var bundleCache: [BundleCacheKey: ResolvedApplicationIcon] = [:]

    convenience init() {
        self.init(loader: WorkspaceApplicationIconLoader())
    }

    init(loader: any ApplicationIconLoading) {
        self.loader = loader
    }

    func resolve(
        identity: ApplicationProcessIdentity,
        pointSize: CGFloat = 24,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) async -> ResolvedApplicationIcon {
        let scaleKey = Int((scale * 100).rounded())
        let processKey = ProcessCacheKey(identity: identity, scale: scaleKey)
        if let cached = processCache[processKey] { return copied(cached, pointSize: pointSize) }
        if let running = await loader.runningIcon(for: identity) {
            let result = ResolvedApplicationIcon(
                image: resizedCopy(running, pointSize: pointSize), source: .runningProcess
            )
            processCache[processKey] = result
            return copied(result, pointSize: pointSize)
        }

        let values = try? identity.bundleURL.resourceValues(forKeys: [
            .contentModificationDateKey, .fileSizeKey
        ])
        let bundle = Bundle(url: identity.bundleURL)
        let bundleKey = BundleCacheKey(
            url: identity.bundleURL,
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize,
            version: bundle?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            build: bundle?.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            scale: scaleKey
        )
        if let cached = bundleCache[bundleKey] { return copied(cached, pointSize: pointSize) }
        if let bundle = await loader.bundleIcon(at: identity.bundleURL) {
            let result = ResolvedApplicationIcon(
                image: resizedCopy(bundle, pointSize: pointSize), source: .bundle
            )
            bundleCache[bundleKey] = result
            return copied(result, pointSize: pointSize)
        }
        let generic = NSImage(systemSymbolName: "app.fill", accessibilityDescription: "Application")
            ?? NSImage(size: NSSize(width: pointSize, height: pointSize))
        return ResolvedApplicationIcon(
            image: resizedCopy(generic, pointSize: pointSize),
            source: .genericApplication
        )
    }

    func invalidateAll() {
        processCache.removeAll()
        bundleCache.removeAll()
    }

    func invalidate(identity: ApplicationProcessIdentity) {
        processCache = processCache.filter { $0.key.identity != identity }
    }

    func invalidate(processIdentifier: Int32, bundleURL: URL?) {
        let canonical = bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
        processCache = processCache.filter {
            $0.key.identity.processIdentifier != processIdentifier
                && (canonical == nil || $0.key.identity.bundleURL != canonical)
        }
    }

    func invalidate(bundleURLs: Set<URL>) {
        let canonical = Set(bundleURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        processCache = processCache.filter { !canonical.contains($0.key.identity.bundleURL) }
        bundleCache = bundleCache.filter { !canonical.contains($0.key.url) }
    }

    func stop() { invalidateAll() }

    private func copied(_ value: ResolvedApplicationIcon, pointSize: CGFloat) -> ResolvedApplicationIcon {
        ResolvedApplicationIcon(image: resizedCopy(value.image, pointSize: pointSize), source: value.source)
    }

    private func resizedCopy(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }
}

@MainActor
struct HUDApplicationPresentation {
    enum Kind: Equatable {
        case cadence
        case knownApplication
        case unavailableApplication
    }

    let identity: ApplicationProcessIdentity?
    let displayName: String
    let icon: NSImage?
    let iconSource: ApplicationIconSource?
    let kind: Kind
    let presentationRevision: Int
    let pinID: UUID?

    static let cadence = HUDApplicationPresentation(
        identity: nil, displayName: "Cadence", icon: nil, iconSource: nil,
        kind: .cadence, presentationRevision: 0, pinID: nil
    )
}

@MainActor
final class ApplicationPresentationArbiter {
    private let resolver: ApplicationIconResolver
    private var live: HUDApplicationPresentation = .cadence
    private var pinned: HUDApplicationPresentation?
    private var presentationRevision = 0
    private var liveRequestRevision = 0
    private var pinRequestRevision = 0
    var onChange: ((HUDApplicationPresentation) -> Void)?

    init(resolver: ApplicationIconResolver) { self.resolver = resolver }

    func updateLive(_ identity: FocusedApplicationIdentity?) {
        liveRequestRevision += 1
        presentationRevision += 1
        let requestedRevision = liveRequestRevision
        guard let identity else {
            live = .cadence
            if pinned == nil { onChange?(live) }
            return
        }
        live = placeholder(identity: identity.process, name: identity.displayName, pinID: nil)
        if pinned == nil { onChange?(live) }
        if identity.displayName != nil {
            loadIcon(
                identity: identity.process, name: identity.displayName,
                pinID: nil, requestedRevision: requestedRevision
            )
        }
    }

    func pin(_ capture: ApplicationTargetCapture, displayName: String?) {
        pinRequestRevision += 1
        presentationRevision += 1
        let requestedRevision = pinRequestRevision
        pinned = placeholder(identity: capture.process, name: displayName, pinID: capture.id)
        onChange?(pinned!)
        if displayName != nil {
            loadIcon(
                identity: capture.process, name: displayName,
                pinID: capture.id, requestedRevision: requestedRevision
            )
        }
    }

    func clearPin(_ id: UUID) {
        guard pinned?.pinID == id else { return }
        pinned = nil
        pinRequestRevision += 1
        presentationRevision += 1
        onChange?(live)
    }

    func markTerminated(
        identity: ApplicationProcessIdentity?,
        processIdentifier: Int32,
        bundleURL: URL?,
        launchDate: Date?
    ) {
        let matches: (HUDApplicationPresentation) -> Bool = { presentation in
            guard let process = presentation.identity else { return false }
            if let identity { return process == identity }
            return process.matchesTermination(
                processIdentifier: processIdentifier,
                bundleIdentifier: nil,
                bundleURL: bundleURL,
                launchDate: launchDate
            )
        }
        if let pinned, matches(pinned) {
            pinRequestRevision += 1
            presentationRevision += 1
            self.pinned = unavailable(identity: pinned.identity, pinID: pinned.pinID)
            onChange?(self.pinned!)
        }
        if matches(live) {
            liveRequestRevision += 1
            presentationRevision += 1
            live = unavailable(identity: live.identity, pinID: nil)
            if pinned == nil { onChange?(live) }
        }
    }

    func stop() {
        liveRequestRevision += 1
        pinRequestRevision += 1
        pinned = nil
        resolver.stop()
    }

    private func loadIcon(
        identity: ApplicationProcessIdentity,
        name: String?,
        pinID: UUID?,
        requestedRevision: Int
    ) {
        Task { [weak self] in
            guard let self else { return }
            let resolved = await resolver.resolve(identity: identity)
            guard let name else { return }
            let presentation = HUDApplicationPresentation(
                identity: identity, displayName: name, icon: resolved.image,
                iconSource: resolved.source, kind: .knownApplication,
                presentationRevision: presentationRevision, pinID: pinID
            )
            if let pinID {
                guard requestedRevision == pinRequestRevision,
                      pinned?.pinID == pinID, pinned?.identity == identity else { return }
                pinned = presentation
                onChange?(presentation)
            } else {
                guard requestedRevision == liveRequestRevision, live.identity == identity else { return }
                live = presentation
                if pinned == nil { onChange?(presentation) }
            }
        }
    }

    private func placeholder(
        identity: ApplicationProcessIdentity,
        name: String?,
        pinID: UUID?
    ) -> HUDApplicationPresentation {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable(identity: identity, pinID: pinID)
        }
        return HUDApplicationPresentation(
            identity: identity, displayName: name, icon: nil, iconSource: .genericApplication,
            kind: .knownApplication, presentationRevision: presentationRevision, pinID: pinID
        )
    }

    private func unavailable(
        identity: ApplicationProcessIdentity?,
        pinID: UUID?
    ) -> HUDApplicationPresentation {
        HUDApplicationPresentation(
            identity: identity, displayName: "Application unavailable", icon: nil,
            iconSource: .genericApplication, kind: .unavailableApplication,
            presentationRevision: presentationRevision, pinID: pinID
        )
    }
}
