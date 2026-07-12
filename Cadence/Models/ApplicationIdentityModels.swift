import Foundation

struct InstalledApplicationDescriptor: Equatable, Identifiable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let displayName: String
    let version: String?
    let build: String?
    let isInstalled: Bool
    let isRunning: Bool

    var id: URL { bundleURL }
}

struct InstalledApplicationBundleMetadata: Equatable, Sendable {
    let isApplicationBundle: Bool
    let bundleIdentifier: String?
    let displayName: String
    let executableURL: URL?
    let executableExists: Bool
    let executableIsRegularFile: Bool
    let executableIsExecutable: Bool
    let version: String?
    let build: String?

    static func application(
        id: String,
        name: String,
        executableURL: URL? = nil,
        executableExists: Bool = true,
        executableIsRegularFile: Bool = true,
        executableIsExecutable: Bool = true,
        version: String? = nil,
        build: String? = nil
    ) -> InstalledApplicationBundleMetadata {
        .init(
            isApplicationBundle: true,
            bundleIdentifier: id,
            displayName: name,
            executableURL: executableURL,
            executableExists: executableExists,
            executableIsRegularFile: executableIsRegularFile,
            executableIsExecutable: executableIsExecutable,
            version: version,
            build: build
        )
    }

    static func invalidApplication(name: String) -> InstalledApplicationBundleMetadata {
        .init(
            isApplicationBundle: true,
            bundleIdentifier: nil,
            displayName: name,
            executableURL: nil,
            executableExists: false,
            executableIsRegularFile: false,
            executableIsExecutable: false,
            version: nil,
            build: nil
        )
    }
}

struct InstalledApplicationCatalogSnapshot: Equatable, Sendable {
    let generation: Int
    let applications: [InstalledApplicationDescriptor]

    static let empty = InstalledApplicationCatalogSnapshot(generation: 0, applications: [])
}

enum InstalledApplicationCatalogEvent: Hashable, Sendable {
    case mounted(root: URL)
    case unmounted(root: URL)
    case volumeRelocated(oldRoot: URL, newRoot: URL)
    case applicationsChanged
}

enum ApplicationIdentityResolution: Equatable, Sendable {
    case exact(InstalledApplicationDescriptor)
    case uniqueRebind(InstalledApplicationDescriptor)
    case ambiguous
    case missing
    case invalid

    var isUniqueRebind: Bool {
        if case .uniqueRebind = self { return true }
        return false
    }
}

enum ResolvedApplicationSelection: Equatable, Sendable {
    case exact(InstalledApplicationDescriptor)
    case missing
    case ambiguous
    case invalid
}

struct ApplicationReference: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let bundleIdentifier: String
    let lastKnownBundleURL: URL
    let lastKnownDisplayName: String

    init(
        schemaVersion: Int = ApplicationReference.currentSchemaVersion,
        id: UUID = UUID(),
        bundleIdentifier: String,
        lastKnownBundleURL: URL,
        lastKnownDisplayName: String
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.lastKnownBundleURL = lastKnownBundleURL
        self.lastKnownDisplayName = lastKnownDisplayName
    }

    func normalized() -> ApplicationReference {
        ApplicationReference(
            schemaVersion: schemaVersion,
            id: id,
            bundleIdentifier: bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
            lastKnownBundleURL: lastKnownBundleURL.standardizedFileURL,
            lastKnownDisplayName: lastKnownDisplayName.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct ActiveApplicationIdentity: Equatable, Sendable {
    let bundleIdentifier: String
    let bundleURL: URL
    let displayName: String
    let processIdentifier: Int32
}

struct ApplicationPresentation: Equatable, Sendable {
    let displayName: String
    let bundleURL: URL?
}
