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
