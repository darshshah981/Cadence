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
        guard let application = workspace.runningApplications.first(where: {
            $0.processIdentifier == processIdentifier
        }) else { return nil }
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
}

@MainActor
final class RuntimeApplicationProcessAuthority: RuntimeApplicationProcessAuthorizing {
    private struct Key: Hashable {
        let processIdentifier: Int32
        let bundleIdentifier: String
        let bundleURL: URL
        let launchDate: Date
    }

    private let source: any RuntimeApplicationProcessSourcing
    private var incarnations: [Key: UUID] = [:]

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
        let incarnation = incarnations[key] ?? UUID()
        incarnations[key] = incarnation
        return (
            ApplicationProcessIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                bundleURL: bundleURL,
                incarnation: incarnation,
                launchDate: launchDate
            ),
            snapshot.displayName
        )
    }

    func verify(_ identity: ApplicationProcessIdentity) -> Bool {
        guard let launchDate = identity.launchDate,
              let captured = try? capture(
                processIdentifier: identity.processIdentifier,
                expectedBundleIdentifier: identity.bundleIdentifier
              ).identity else { return false }
        return captured == identity && captured.launchDate == launchDate
    }
}
