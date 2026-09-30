import Foundation
import Security
import Testing
@testable import Cadence

@MainActor
struct ScribePersistentMemoryDomainStoreTests {
    @Test
    func invalidLocationAndBundleFailWithoutCreatingStorage() {
        #expect(throws: ScribePersistentMemoryDomainError.invalidLocation) {
            try ScribePersistentMemoryDomainStore(directoryURL: URL(string: "https://example.test/memory/")!, applicationBundleIdentifier: "com.example.Cadence")
        }
        #expect(throws: ScribePersistentMemoryDomainError.invalidLocation) {
            try ScribePersistentMemoryDomainStore(directoryURL: URL(fileURLWithPath: "/tmp/file.json", isDirectory: false), applicationBundleIdentifier: "com.example.Cadence")
        }
        #expect(throws: ScribePersistentMemoryKeyError.invalidNamespace) {
            try ScribePersistentMemoryDomainStore(directoryURL: temporaryDirectory(), applicationBundleIdentifier: "../invalid")
        }
    }

    @Test
    func constructionUnconfirmedCreationAndAbsentReadHaveNoWrites() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = 0
        let owner = try ScribePersistentMemoryDomainStore(directoryURL: directory,
            applicationBundleIdentifier: "com.example.Cadence", makeID: { generated += 1; return UUID() })
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: ScribePersistentMemoryDomainError.confirmationRequired) {
            try owner.create(authority: .notConfirmed)
        }
        #expect(try owner.load() == nil)
        #expect(generated == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func confirmedCreationAndReopeningKeepNamespaceAndKeyIdentity() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var generated = 0
        let owner = try ScribePersistentMemoryDomainStore(directoryURL: directory,
            applicationBundleIdentifier: "com.example.Cadence", makeID: { generated += 1; return UUID() })
        let domain = try owner.create(authority: .confirmedByUser)
        #expect(generated == 2)
        let manifest = try Data(contentsOf: owner.namespaceURL)
        #expect(!String(decoding: manifest, as: UTF8.self).contains(directory.path))
        let backend = DomainKeyBackend()
        let keys = try owner.makeKeyStore(for: domain, backend: backend)
        #expect(backend.calls == 0)
        #expect(try keys.provision(authority: .confirmedByUser) == .created)
        let bytes = try keys.keyData()
        let reopened = try ScribePersistentMemoryDomainStore(directoryURL: directory,
            applicationBundleIdentifier: "com.example.Cadence", makeID: { generated += 1; return UUID() })
        #expect(try reopened.load() == domain)
        #expect(try reopened.create(authority: .confirmedByUser) == domain)
        #expect(generated == 2)
        let reopenedKeys = try reopened.makeKeyStore(for: domain, backend: backend)
        #expect(reopenedKeys.keychainAccount == keys.keychainAccount)
        #expect(try reopenedKeys.keyData() == bytes)
        #expect(try Data(contentsOf: owner.namespaceURL) == manifest)
        #expect(!FileManager.default.fileExists(atPath: owner.storeURL.path))
    }

    @Test(arguments: [Data(), Data([0]), Data(repeating: 7, count: 5_000)])
    func encryptedBytesWithoutNamespaceCannotCreateReplacementIdentity(_ bytes: Data) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try makeOwner(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: owner.storeURL)
        #expect(throws: ScribePersistentMemoryDomainError.orphanedEncryptedStore) { try owner.load() }
        #expect(throws: ScribePersistentMemoryDomainError.orphanedEncryptedStore) {
            try owner.create(authority: .confirmedByUser)
        }
        #expect(try Data(contentsOf: owner.storeURL) == bytes)
        #expect(!FileManager.default.fileExists(atPath: owner.namespaceURL.path))
    }

    @Test(arguments: [Data(), Data("not JSON".utf8), Data("{\"schemaVersion\":1}".utf8)])
    func corruptNamespaceIsNeverOverwritten(_ bytes: Data) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try makeOwner(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: owner.namespaceURL)
        #expect(throws: ScribePersistentMemoryDomainError.unreadable) { try owner.create(authority: .confirmedByUser) }
        #expect(try Data(contentsOf: owner.namespaceURL) == bytes)
    }

    @Test
    func futureSchemaIsPreservedWithoutRequiringCurrentFields() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try makeOwner(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\":2,\"future\":true}".utf8)
        try future.write(to: owner.namespaceURL)
        #expect(throws: ScribePersistentMemoryDomainError.unknownSchema) { try owner.load() }
        #expect(throws: ScribePersistentMemoryDomainError.unknownSchema) { try owner.create(authority: .confirmedByUser) }
        #expect(try Data(contentsOf: owner.namespaceURL) == future)
    }

    @Test
    func copiedNamespaceCannotOpenAnotherLocationOrBuild() throws {
        let directory = temporaryDirectory(), other = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: other) }
        let owner = try makeOwner(directory)
        _ = try owner.create(authority: .confirmedByUser)
        let bytes = try Data(contentsOf: owner.namespaceURL)
        let moved = try makeOwner(other)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try bytes.write(to: moved.namespaceURL)
        #expect(throws: ScribePersistentMemoryDomainError.locationMismatch) { try moved.create(authority: .confirmedByUser) }
        let debug = try ScribePersistentMemoryDomainStore(directoryURL: directory, applicationBundleIdentifier: "com.example.Cadence.debug")
        #expect(throws: ScribePersistentMemoryDomainError.applicationMismatch) { try debug.load() }
        #expect(try Data(contentsOf: moved.namespaceURL) == bytes)
    }

    @Test
    func removedOrReplacedDomainRejectsOldKeyFactoryRequest() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try makeOwner(directory)
        let old = try owner.create(authority: .confirmedByUser)
        try FileManager.default.removeItem(at: owner.namespaceURL)
        let backend = DomainKeyBackend()
        #expect(throws: ScribePersistentMemoryDomainError.domainChanged) { try owner.makeKeyStore(for: old, backend: backend) }
        let fresh = try owner.create(authority: .confirmedByUser)
        #expect(fresh != old)
        #expect(throws: ScribePersistentMemoryDomainError.domainChanged) { try owner.makeKeyStore(for: old, backend: backend) }
        #expect(backend.calls == 0)
    }

    @Test
    func concurrentEncryptedStoreLockPreventsNamespaceCreation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try makeOwner(directory)
        let files = SystemScribePersistentMemoryFileAccess()
        try files.withExclusiveLock(at: owner.storeURL) {
            #expect(throws: ScribePersistentMemoryError.storeBusy) { try owner.create(authority: .confirmedByUser) }
            #expect(!FileManager.default.fileExists(atPath: owner.namespaceURL.path))
        }
        #expect(try owner.create(authority: .confirmedByUser) == owner.load())
    }

    @Test
    func namespaceSymlinksAndOversizedMetadataArePreserved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try makeOwner(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("unrelated")
        let bytes = Data(repeating: 7, count: 4_097)
        try bytes.write(to: other)
        try FileManager.default.createSymbolicLink(at: owner.namespaceURL, withDestinationURL: other)
        #expect(throws: ScribePersistentMemoryError.ioFailure) { try owner.create(authority: .confirmedByUser) }
        #expect(try Data(contentsOf: other) == bytes)
        try FileManager.default.removeItem(at: owner.namespaceURL)
        try bytes.write(to: owner.namespaceURL)
        #expect(throws: ScribePersistentMemoryError.capacityExceeded) { try owner.load() }
        #expect(try Data(contentsOf: owner.namespaceURL) == bytes)
    }

    @Test
    func failedAtomicWriteDoesNotReturnAnUnpersistedDomain() throws {
        let files = FailingDomainFiles()
        let owner = try ScribePersistentMemoryDomainStore(directoryURL: temporaryDirectory(),
            applicationBundleIdentifier: "com.example.Cadence", fileAccess: files)
        #expect(throws: ScribePersistentMemoryError.ioFailure) { try owner.create(authority: .confirmedByUser) }
        #expect(try owner.load() == nil)
        #expect(files.writeAttempts == 1)
    }

    private func makeOwner(_ directory: URL) throws -> ScribePersistentMemoryDomainStore {
        try .init(directoryURL: directory, applicationBundleIdentifier: "com.example.Cadence")
    }
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/cadence-memory-domain-" + UUID().uuidString, isDirectory: true)
    }
}

@MainActor
private final class FailingDomainFiles: ScribePersistentMemoryFileAccess {
    var writeAttempts = 0
    func withExclusiveLock<T>(at url: URL, _ operation: () throws -> T) throws -> T { try operation() }
    func read(at url: URL, maximumBytes: Int) throws -> Data? { nil }
    func writeAtomically(_ data: Data, to url: URL) throws {
        writeAttempts += 1
        throw ScribePersistentMemoryError.ioFailure
    }
}

/// In-memory Security substitute. No test in this suite contacts host Keychain.
final class DomainKeyBackend: ScribePersistentMemorySecurityBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var callCount = 0
    var calls: Int { lock.withLock { callCount } }
    private func identity(_ values: [String: Any]) -> String {
        (values[kSecAttrService as String] as? String ?? "") + ":" + (values[kSecAttrAccount as String] as? String ?? "")
    }
    func copy(_ query: [String: Any]) -> ScribePersistentMemorySecurityDataResult {
        lock.withLock {
            callCount += 1
            let value = items[identity(query)]
            return .init(status: value == nil ? errSecItemNotFound : errSecSuccess, data: value)
        }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            callCount += 1
            let id = identity(attributes)
            guard items[id] == nil else { return errSecDuplicateItem }
            items[id] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock { callCount += 1; items.removeValue(forKey: identity(query)); return errSecSuccess }
    }
    func randomKeyData() -> ScribePersistentMemorySecurityDataResult {
        lock.withLock { callCount += 1; return .init(status: errSecSuccess, data: Data(repeating: 91, count: 32)) }
    }
}
