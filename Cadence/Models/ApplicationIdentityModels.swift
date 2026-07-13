import Foundation

struct InstalledApplicationDescriptor: Equatable, Identifiable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let displayName: String
    let version: String?
    let build: String?
    let isInstalled: Bool
    let isRunning: Bool
    let isUserFacing: Bool

    init(
        bundleURL: URL, bundleIdentifier: String, displayName: String,
        version: String?, build: String?, isInstalled: Bool, isRunning: Bool,
        isUserFacing: Bool = true
    ) {
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.build = build
        self.isInstalled = isInstalled
        self.isRunning = isRunning
        self.isUserFacing = isUserFacing
    }

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
    let isUIElement: Bool
    let isBackgroundOnly: Bool

    init(
        isApplicationBundle: Bool, bundleIdentifier: String?, displayName: String,
        executableURL: URL?, executableExists: Bool, executableIsRegularFile: Bool,
        executableIsExecutable: Bool, version: String?, build: String?,
        isUIElement: Bool = false, isBackgroundOnly: Bool = false
    ) {
        self.isApplicationBundle = isApplicationBundle
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.executableURL = executableURL
        self.executableExists = executableExists
        self.executableIsRegularFile = executableIsRegularFile
        self.executableIsExecutable = executableIsExecutable
        self.version = version
        self.build = build
        self.isUIElement = isUIElement
        self.isBackgroundOnly = isBackgroundOnly
    }

    static func application(
        id: String,
        name: String,
        executableURL: URL? = nil,
        executableExists: Bool = true,
        executableIsRegularFile: Bool = true,
        executableIsExecutable: Bool = true,
        version: String? = nil,
        build: String? = nil,
        isUIElement: Bool = false,
        isBackgroundOnly: Bool = false
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
            build: build,
            isUIElement: isUIElement,
            isBackgroundOnly: isBackgroundOnly
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
            build: nil,
            isUIElement: false,
            isBackgroundOnly: false
        )
    }
}

enum InstalledApplicationPickerProjection {
    static let defaultLimit = 12

    static func applications(
        from catalog: [InstalledApplicationDescriptor], query: String,
        limit: Int = defaultLimit
    ) -> [InstalledApplicationDescriptor] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let eligible = catalog.filter(\.isUserFacing)
        let matching = normalizedQuery.isEmpty ? eligible : eligible.filter {
            $0.displayName.localizedCaseInsensitiveContains(normalizedQuery)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(normalizedQuery)
        }
        let ranked = matching.sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.bundleURL.standardizedFileURL.path < $1.bundleURL.standardizedFileURL.path
        }
        return normalizedQuery.isEmpty ? Array(ranked.prefix(max(0, limit))) : ranked
    }
}

enum ApplicationSettingsConfigurationState: Equatable, Sendable {
    case configured(ApplicationConfiguration)
    case unconfigured

    static func resolve(
        application: InstalledApplicationDescriptor,
        configurations: [ApplicationConfiguration]
    ) -> ApplicationSettingsConfigurationState {
        guard let configuration = ApplicationIdentityResolver.runtimeExactConfiguration(
            bundleIdentifier: application.bundleIdentifier,
            bundleURL: application.bundleURL,
            configurations: configurations
        ) else { return .unconfigured }
        return .configured(configuration)
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
