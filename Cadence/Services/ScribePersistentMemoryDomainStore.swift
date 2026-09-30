import CryptoKit
import Foundation
import OSLog

private let scribePersistentMemoryDomainLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribePersistentMemoryDomainStore"
)

enum ScribePersistentMemoryDomainError: Error, Equatable {
    case invalidLocation, confirmationRequired, unreadable, unknownSchema
    case applicationMismatch, locationMismatch, orphanedEncryptedStore, domainChanged
}

enum ScribePersistentMemoryDomainCreationAuthority: Equatable {
    case notConfirmed, confirmedByUser
}

struct ScribePersistentMemoryDomain: Equatable, Sendable {
    let namespace: ScribePersistentMemoryKeyNamespace
    let storeURL: URL
}

/// Owns the content-free local namespace required to reopen memory after restart.
/// Construction is inert. Reading does not create directories, a namespace, a
/// Keychain item, or consent. Creation is an explicit, locked, atomic operation.
/// This owner performs no migrations, resets, repairs or memory activation.
@MainActor
final class ScribePersistentMemoryDomainStore {
    private struct Manifest: Codable {
        let schemaVersion: Int
        let applicationBundleIdentifier: String
        let installationID: UUID
        let storageDomainID: UUID
        let storePathSHA256: String
    }

    let storeURL: URL
    let namespaceURL: URL
    private let applicationBundleIdentifier: String
    private let files: any ScribePersistentMemoryFileAccess
    private let makeID: () -> UUID
    private static let maximumManifestBytes = 4_096

    init(directoryURL: URL, applicationBundleIdentifier: String,
         fileAccess: (any ScribePersistentMemoryFileAccess)? = nil,
         makeID: @escaping () -> UUID = UUID.init) throws {
        guard directoryURL.isFileURL, directoryURL.hasDirectoryPath else {
            throw ScribePersistentMemoryDomainError.invalidLocation
        }
        try ScribePersistentMemoryKeyNamespace.validateApplicationBundleIdentifier(applicationBundleIdentifier)
        let directory = directoryURL.standardizedFileURL
        self.storeURL = directory.appendingPathComponent("memory.json", isDirectory: false)
        self.namespaceURL = directory.appendingPathComponent("namespace.json", isDirectory: false)
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.files = fileAccess ?? SystemScribePersistentMemoryFileAccess()
        self.makeID = makeID
    }

    /// True absence is distinct from missing identity for an existing encrypted
    /// file. Even an empty or oversized encrypted file must never trigger new IDs.
    func load() throws -> ScribePersistentMemoryDomain? {
        guard let bytes = try files.read(at: namespaceURL, maximumBytes: Self.maximumManifestBytes) else {
            try requireAbsentEncryptedStore()
            return nil
        }
        // Read the version before decoding its fields so future formats are
        // preserved as unsupported rather than mistaken for fresh storage.
        struct Version: Decodable { let schemaVersion: Int }
        guard let version = try? JSONDecoder().decode(Version.self, from: bytes) else {
            throw ScribePersistentMemoryDomainError.unreadable
        }
        guard version.schemaVersion == 1 else { throw ScribePersistentMemoryDomainError.unknownSchema }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else {
            throw ScribePersistentMemoryDomainError.unreadable
        }
        guard manifest.applicationBundleIdentifier == applicationBundleIdentifier else {
            throw ScribePersistentMemoryDomainError.applicationMismatch
        }
        guard manifest.storePathSHA256 == pathHash else { throw ScribePersistentMemoryDomainError.locationMismatch }
        let namespace = try ScribePersistentMemoryKeyNamespace(
            applicationBundleIdentifier: manifest.applicationBundleIdentifier,
            installationID: manifest.installationID, storageDomainID: manifest.storageDomainID
        )
        return .init(namespace: namespace, storeURL: storeURL)
    }

    /// Uses the encrypted store's lock, shared with key provisioning and data
    /// writers. Repeated confirmed creation reuses an existing valid namespace.
    /// A failed write never authorizes constructing a key with unpersisted IDs.
    func create(authority: ScribePersistentMemoryDomainCreationAuthority) throws -> ScribePersistentMemoryDomain {
        guard authority == .confirmedByUser else { throw ScribePersistentMemoryDomainError.confirmationRequired }
        return try files.withExclusiveLock(at: storeURL) {
            if let existing = try load() { return existing }
            let manifest = Manifest(schemaVersion: 1, applicationBundleIdentifier: applicationBundleIdentifier,
                                    installationID: makeID(), storageDomainID: makeID(), storePathSHA256: pathHash)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try files.writeAtomically(try encoder.encode(manifest), to: namespaceURL)
            guard let persisted = try load(),
                  persisted.namespace.installationID == manifest.installationID,
                  persisted.namespace.storageDomainID == manifest.storageDomainID else {
                throw ScribePersistentMemoryDomainError.domainChanged
            }
            return persisted
        }
    }

    /// Recheck stored identity before opening a key store. This does not read or
    /// provision a key. Runtime teardown/reset must invalidate its store objects;
    /// this factory is not itself an ongoing consent or revocation monitor.
    func makeKeyStore(for domain: ScribePersistentMemoryDomain,
                      backend: any ScribePersistentMemorySecurityBackend = SystemScribePersistentMemorySecurityBackend()) throws -> KeychainScribePersistentMemoryKeyStore {
        guard try load() == domain else { throw ScribePersistentMemoryDomainError.domainChanged }
        return try .init(namespace: domain.namespace, storeURL: storeURL, backend: backend, fileAccess: files)
    }

    private var pathHash: String {
        SHA256.hash(data: Data(storeURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func requireAbsentEncryptedStore() throws {
        do {
            guard try files.read(at: storeURL, maximumBytes: 1) == nil else {
                throw ScribePersistentMemoryDomainError.orphanedEncryptedStore
            }
        } catch ScribePersistentMemoryError.capacityExceeded {
            throw ScribePersistentMemoryDomainError.orphanedEncryptedStore
        }
    }
}
