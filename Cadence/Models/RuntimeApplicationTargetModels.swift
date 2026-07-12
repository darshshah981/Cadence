import Foundation

struct ApplicationProcessIdentity: Equatable, Hashable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let bundleURL: URL
    let incarnation: UUID
    let launchDate: Date?

    init(
        processIdentifier: Int32,
        bundleIdentifier: String,
        bundleURL: URL,
        incarnation: UUID,
        launchDate: Date? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        self.incarnation = incarnation
        self.launchDate = launchDate
    }
}

struct FocusedApplicationIdentity: Equatable, Sendable {
    let process: ApplicationProcessIdentity
    let displayName: String?
    let identityRevision: Int
    let presentationRevision: Int
    let observedAt: Date
}

struct ApplicationTargetCapture: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case dictation
        case scribeAccessibility
    }

    let id: UUID
    let process: ApplicationProcessIdentity
    let identityRevision: Int
    let captureRevision: Int
    let capturedAt: Date
    let source: Source
    let displayName: String?

    init(
        id: UUID = UUID(),
        process: ApplicationProcessIdentity,
        identityRevision: Int,
        captureRevision: Int,
        capturedAt: Date = Date(),
        source: Source,
        displayName: String? = nil
    ) {
        self.id = id
        self.process = process
        self.identityRevision = identityRevision
        self.captureRevision = captureRevision
        self.capturedAt = capturedAt
        self.source = source
        self.displayName = displayName
    }
}

struct FocusedApplicationSample: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let bundleURL: URL
    let displayName: String?
    let launchDate: Date?
}

enum FocusedApplicationEvent: Equatable, Sendable {
    case activated
    case launched(FocusedApplicationSample)
    case terminated(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        bundleURL: URL?,
        launchDate: Date?
    )
    case woke
    case sessionChanged
}

enum ApplicationTargetAuthorityError: Error, Equatable, Sendable {
    case noExternalTarget
    case targetChanged
}
