import AppKit
import Foundation

struct RuntimeApplicationProcessSnapshot: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let bundleURL: URL?
    let displayName: String?
    let launchDate: Date?
}

@MainActor
protocol RuntimeApplicationProcessSourcing: AnyObject {
    func process(processIdentifier: Int32) -> RuntimeApplicationProcessSnapshot?
}

@MainActor
final class WorkspaceRuntimeApplicationProcessSource: RuntimeApplicationProcessSourcing {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) { self.workspace = workspace }

    func process(processIdentifier: Int32) -> RuntimeApplicationProcessSnapshot? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return nil }
        return RuntimeApplicationProcessSnapshot(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL,
            displayName: application.localizedName,
            launchDate: application.launchDate
        )
    }
}

@MainActor
protocol RuntimeApplicationProcessAuthorizing: AnyObject {
    func capture(
        processIdentifier: Int32,
        expectedBundleIdentifier: String?
    ) throws -> (identity: ApplicationProcessIdentity, displayName: String?)
    func verify(_ identity: ApplicationProcessIdentity) -> Bool
    func release(_ identity: ApplicationProcessIdentity)
}

extension RuntimeApplicationProcessAuthorizing {
    func release(_ identity: ApplicationProcessIdentity) {}
}

@MainActor
final class RuntimeApplicationProcessAuthority: RuntimeApplicationProcessAuthorizing {
    private struct Key: Hashable {
        let processIdentifier: Int32
        let bundleIdentifier: String
        let bundleURL: URL
        let launchDate: Date
    }

    private struct IncarnationRecord {
        let id: UUID
        var activeCaptureCount: Int
        var lastAccess: UInt64
    }

    private static let maximumInactiveIncarnations = 128
    private let source: any RuntimeApplicationProcessSourcing
    private var incarnations: [Key: IncarnationRecord] = [:]
    private var accessRevision: UInt64 = 0

    convenience init() { self.init(source: WorkspaceRuntimeApplicationProcessSource()) }

    init(source: any RuntimeApplicationProcessSourcing) { self.source = source }

    func capture(
        processIdentifier: Int32,
        expectedBundleIdentifier: String?
    ) throws -> (identity: ApplicationProcessIdentity, displayName: String?) {
        guard let snapshot = source.process(processIdentifier: processIdentifier),
              snapshot.processIdentifier == processIdentifier,
              let bundleIdentifier = snapshot.bundleIdentifier,
              expectedBundleIdentifier == nil || expectedBundleIdentifier == bundleIdentifier,
              let bundleURL = snapshot.bundleURL?.standardizedFileURL.resolvingSymlinksInPath(),
              let launchDate = snapshot.launchDate else {
            throw ScribeContextError.noFocusedTarget
        }
        let key = Key(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        accessRevision &+= 1
        var record = incarnations[key] ?? IncarnationRecord(
            id: UUID(), activeCaptureCount: 0, lastAccess: accessRevision
        )
        record.activeCaptureCount += 1
        record.lastAccess = accessRevision
        incarnations[key] = record
        pruneInactiveIncarnations()
        return (
            ApplicationProcessIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleURL,
                incarnation: record.id,
                launchDate: launchDate
            ),
            snapshot.displayName
        )
    }

    func verify(_ identity: ApplicationProcessIdentity) -> Bool {
        guard let launchDate = identity.launchDate,
              let captured = resolvedIdentity(
                processIdentifier: identity.processIdentifier,
                expectedBundleIdentifier: identity.bundleIdentifier
              ) else { return false }
        return captured == identity && captured.launchDate == launchDate
    }

    func release(_ identity: ApplicationProcessIdentity) {
        guard let key = key(for: identity),
              var record = incarnations[key],
              record.id == identity.incarnation else { return }
        record.activeCaptureCount = max(0, record.activeCaptureCount - 1)
        incarnations[key] = record
        pruneInactiveIncarnations()
    }

    private func resolvedIdentity(
        processIdentifier: Int32,
        expectedBundleIdentifier: String
    ) -> ApplicationProcessIdentity? {
        guard let snapshot = source.process(processIdentifier: processIdentifier),
              snapshot.processIdentifier == processIdentifier,
              snapshot.bundleIdentifier == expectedBundleIdentifier,
              let bundleURL = snapshot.bundleURL?.standardizedFileURL.resolvingSymlinksInPath(),
              let launchDate = snapshot.launchDate else { return nil }
        let key = Key(
            processIdentifier: processIdentifier,
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: bundleURL,
            launchDate: launchDate
        )
        guard var record = incarnations[key] else { return nil }
        accessRevision &+= 1
        record.lastAccess = accessRevision
        incarnations[key] = record
        return ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: bundleURL,
            incarnation: record.id,
            launchDate: launchDate
        )
    }

    private func key(for identity: ApplicationProcessIdentity) -> Key? {
        guard let launchDate = identity.launchDate else { return nil }
        return Key(
            processIdentifier: identity.processIdentifier,
            bundleIdentifier: identity.bundleIdentifier,
            bundleURL: identity.bundleURL,
            launchDate: launchDate
        )
    }

    private func pruneInactiveIncarnations() {
        let inactive = incarnations.filter { $0.value.activeCaptureCount == 0 }
        guard inactive.count > Self.maximumInactiveIncarnations else { return }
        let removalCount = inactive.count - Self.maximumInactiveIncarnations
        for entry in inactive.sorted(by: { $0.value.lastAccess < $1.value.lastAccess })
            .prefix(removalCount) {
            incarnations.removeValue(forKey: entry.key)
        }
    }
}
