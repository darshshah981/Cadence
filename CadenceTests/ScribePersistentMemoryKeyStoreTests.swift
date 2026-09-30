import Foundation
import Security
import Testing
@testable import Cadence

@MainActor
struct ScribePersistentMemoryKeyStoreTests {
    @Test
    func constructionAndMissingKeyReadNeverProvisionOrTouchFiles() throws {
        let fixture = PersistentKeyFixture()
        let store = try fixture.makeStore()
        #expect(fixture.events.values.isEmpty)
        let provider: any ScribePersistentMemoryKeyProviding = store
        #expect(throws: ScribePersistentMemoryKeyError.notFound) { try provider.keyData() }
        #expect(fixture.events.values == ["copy"])
        #expect(fixture.backend.snapshot().items.isEmpty)
    }

    @Test
    func provisioningAndDeletionRequireExplicitAuthorityBeforeAnyIO() throws {
        let fixture = PersistentKeyFixture()
        let store = try fixture.makeStore()
        #expect(throws: ScribePersistentMemoryKeyError.confirmationRequired) { try store.provision(authority: .notConfirmed) }
        #expect(throws: ScribePersistentMemoryKeyError.confirmationRequired) { try store.delete(authority: .notConfirmed) }
        #expect(fixture.events.values.isEmpty)
    }

    @Test
    func confirmedProvisioningCreatesExactly32BytesAndSurvivesProviderRestart() throws {
        let fixture = PersistentKeyFixture()
        let store = try fixture.makeStore()
        #expect(try store.provision(authority: .confirmedByUser) == .created)
        #expect(fixture.events.values == ["lock", "read-file", "copy", "random", "add", "copy", "unlock"])
        #expect(try store.keyData() == fixture.generatedKey)
        #expect(try fixture.makeStore().keyData() == fixture.generatedKey)
        #expect(fixture.files.data == nil)
        let snapshot = fixture.backend.snapshot()
        #expect(snapshot.addCount == 1 && snapshot.randomCount == 1 && snapshot.deleteCount == 0)
    }

    @Test
    func securityQueriesAreExactNonSynchronizingAndNoninteractive() throws {
        let fixture = PersistentKeyFixture()
        let store = try fixture.makeStore()
        _ = try store.provision(authority: .confirmedByUser)
        let snapshot = fixture.backend.snapshot()
        let attributes = try #require(snapshot.lastAdd)
        #expect(attributes[kSecClass as String] as! CFString == kSecClassGenericPassword)
        #expect(attributes[kSecAttrService as String] as? String == fixture.namespace.service)
        #expect(attributes[kSecAttrAccount as String] as? String == fixture.account)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)
        #expect(attributes[kSecAttrAccessible as String] as! CFString == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        #expect(attributes[kSecUseAuthenticationUI as String] == nil)
        let read = try #require(snapshot.lastCopy)
        #expect(read[kSecMatchLimit as String] as! CFString == kSecMatchLimitOne)
        #expect(read[kSecReturnData as String] as? Bool == true)
        #expect(read[kSecAttrService as String] as? String == fixture.namespace.service)
        #expect(read[kSecAttrAccount as String] as? String == fixture.account)
    }

    @Test
    func existingValidKeyIsReusedWithoutRotationOrRandomGeneration() throws {
        let fixture = PersistentKeyFixture()
        let old = Data(repeating: 3, count: 32)
        fixture.insert(old)
        let store = try fixture.makeStore()
        #expect(try store.provision(authority: .confirmedByUser) == .alreadyPresent)
        #expect(try store.keyData() == old)
        #expect(fixture.backend.snapshot().addCount == 0 && fixture.backend.snapshot().randomCount == 0)
    }

    @Test
    func anyExistingDataFileBlocksProvisioningAndKeyDeletion() throws {
        for bytes in [Data(), Data([0]), Data("corrupt encrypted store".utf8)] {
            let fixture = PersistentKeyFixture()
            fixture.files.data = bytes
            fixture.insert(Data(repeating: 9, count: 31))
            let store = try fixture.makeStore()
            #expect(throws: ScribePersistentMemoryKeyError.encryptedStoreExists) { try store.provision(authority: .confirmedByUser) }
            #expect(throws: ScribePersistentMemoryKeyError.encryptedStoreExists) { try store.delete(authority: .confirmedByUser) }
            #expect(fixture.files.data == bytes)
            #expect(!fixture.events.values.contains("copy") && !fixture.events.values.contains("random"))
            #expect(fixture.backend.snapshot().deleteCount == 0 && fixture.backend.snapshot().addCount == 0)
        }
    }

    @Test
    func missingOrWellFormedWrongKeyWithEncryptedDataIsNeverReplaced() throws {
        let fixture = PersistentKeyFixture()
        fixture.files.data = Data("existing ciphertext".utf8)
        let store = try fixture.makeStore()
        #expect(throws: ScribePersistentMemoryKeyError.notFound) { try store.keyData() }
        #expect(throws: ScribePersistentMemoryKeyError.encryptedStoreExists) { try store.provision(authority: .confirmedByUser) }
        let wrongKey = Data(repeating: 23, count: 32)
        fixture.insert(wrongKey)
        #expect(try store.keyData() == wrongKey)
        #expect(throws: ScribePersistentMemoryKeyError.encryptedStoreExists) { try store.provision(authority: .confirmedByUser) }
        #expect(try store.keyData() == wrongKey)
        #expect(fixture.backend.snapshot().addCount == 0 && fixture.backend.snapshot().randomCount == 0)
    }

    @Test
    func unavailableStorageOrLockContentionCannotAuthorizeProvisioning() throws {
        let fixture = PersistentKeyFixture()
        let store = try fixture.makeStore()
        fixture.files.readError = .ioFailure
        #expect(throws: ScribePersistentMemoryKeyError.storageUnavailable) { try store.provision(authority: .confirmedByUser) }
        fixture.files.readError = nil
        fixture.files.lockError = .storeBusy
        #expect(throws: ScribePersistentMemoryError.storeBusy) { try store.provision(authority: .confirmedByUser) }
        #expect(fixture.backend.snapshot().addCount == 0 && fixture.backend.snapshot().randomCount == 0)
    }

    @Test
    func malformedExistingKeyAndSuccessfulNondataResultAreNotMissingKeys() throws {
        for length in [0, 31, 33] {
            let fixture = PersistentKeyFixture()
            let bytes = Data(repeating: 5, count: length)
            fixture.insert(bytes)
            let store = try fixture.makeStore()
            #expect(throws: ScribePersistentMemoryKeyError.corrupt) { try store.keyData() }
            #expect(throws: ScribePersistentMemoryKeyError.corrupt) { try store.provision(authority: .confirmedByUser) }
            #expect(fixture.backend.snapshot().items.values.first == bytes)
            #expect(fixture.backend.snapshot().addCount == 0)
        }
        let fixture = PersistentKeyFixture()
        fixture.backend.configure { $0.copyOverride = .init(status: errSecSuccess, data: nil) }
        #expect(throws: ScribePersistentMemoryKeyError.corrupt) { try fixture.makeStore().provision(authority: .confirmedByUser) }
        #expect(fixture.backend.snapshot().addCount == 0)
    }

    @Test
    func securityFailuresRemainTypedAndNeverTriggerReplacement() throws {
        let cases: [(OSStatus, ScribePersistentMemoryKeyError)] = [
            (errSecInteractionNotAllowed, .locked), (errSecAuthFailed, .locked), (errSecUserCanceled, .locked),
            (errSecNotAvailable, .unavailable), (errSecDecode, .corrupt), (errSecParam, .securityFailure(errSecParam))
        ]
        for (status, expected) in cases {
            let fixture = PersistentKeyFixture()
            fixture.backend.configure { $0.copyOverride = .init(status: status, data: nil) }
            let store = try fixture.makeStore()
            #expect(throws: expected) { try store.keyData() }
            #expect(throws: expected) { try store.provision(authority: .confirmedByUser) }
            #expect(fixture.backend.snapshot().addCount == 0 && fixture.backend.snapshot().randomCount == 0)
        }
    }

    @Test
    func randomGenerationFailureOrInvalidLengthDoesNotWriteKeychain() throws {
        for result in [ScribePersistentMemorySecurityDataResult(status: errSecNotAvailable, data: nil),
                       .init(status: errSecSuccess, data: nil), .init(status: errSecSuccess, data: Data(count: 31))] {
            let fixture = PersistentKeyFixture()
            fixture.backend.configure { $0.randomResult = result }
            #expect(throws: ScribePersistentMemoryKeyError.randomGenerationFailed) { try fixture.makeStore().provision(authority: .confirmedByUser) }
            #expect(fixture.backend.snapshot().addCount == 0 && fixture.backend.snapshot().items.isEmpty)
        }
    }

    @Test
    func failedAddDoesNotClaimProvisioningOrAttemptCleanupReplacement() throws {
        let fixture = PersistentKeyFixture()
        fixture.backend.configure { $0.addStatus = errSecNotAvailable }
        #expect(throws: ScribePersistentMemoryKeyError.unavailable) { try fixture.makeStore().provision(authority: .confirmedByUser) }
        let snapshot = fixture.backend.snapshot()
        #expect(snapshot.items.isEmpty && snapshot.addCount == 1 && snapshot.deleteCount == 0)
    }

    @Test
    func duplicateAddReusesValidatedWinnerWithoutOverwritingIt() throws {
        let fixture = PersistentKeyFixture()
        let winner = Data(repeating: 42, count: 32)
        fixture.backend.configure { $0.addStatus = errSecDuplicateItem; $0.insertDuringAdd = winner }
        let store = try fixture.makeStore()
        #expect(try store.provision(authority: .confirmedByUser) == .alreadyPresent)
        #expect(try store.keyData() == winner)
        #expect(fixture.backend.snapshot().deleteCount == 0)
        let invalid = PersistentKeyFixture()
        invalid.backend.configure { $0.addStatus = errSecDuplicateItem; $0.insertDuringAdd = Data(count: 1) }
        #expect(throws: ScribePersistentMemoryKeyError.corrupt) { try invalid.makeStore().provision(authority: .confirmedByUser) }
        #expect(invalid.backend.snapshot().items.values.first == Data(count: 1))
    }

    @Test
    func readbackMismatchAfterAddFailsWithoutDeletingOtherKey() throws {
        let fixture = PersistentKeyFixture()
        let changed = Data(repeating: 99, count: 32)
        fixture.backend.configure { $0.insertDuringAdd = changed }
        #expect(throws: ScribePersistentMemoryKeyError.keyChanged) { try fixture.makeStore().provision(authority: .confirmedByUser) }
        #expect(fixture.backend.snapshot().items.values.first == changed)
        #expect(fixture.backend.snapshot().deleteCount == 0)
    }

    @Test
    func keysAreNotCachedAcrossRemovalOrLockStateChanges() throws {
        let fixture = PersistentKeyFixture()
        fixture.insert(fixture.generatedKey)
        let store = try fixture.makeStore()
        #expect(try store.keyData() == fixture.generatedKey)
        fixture.backend.configure { $0.items.removeAll() }
        #expect(throws: ScribePersistentMemoryKeyError.notFound) { try store.keyData() }
        fixture.backend.configure { $0.copyOverride = .init(status: errSecInteractionNotAllowed, data: nil) }
        #expect(throws: ScribePersistentMemoryKeyError.locked) { try store.keyData() }
    }

    @Test
    func explicitDeletionTargetsOnlyOneNamespaceAndIsIdempotent() throws {
        let fixture = PersistentKeyFixture()
        fixture.insert(fixture.generatedKey)
        let other = try ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: fixture.namespace.applicationBundleIdentifier,
            installationID: fixture.namespace.installationID, storageDomainID: UUID())
        let otherAccount = try fixture.makeStore(namespace: other).keychainAccount
        fixture.backend.configure { $0.items[PersistentKeyBackend.index(other.service, otherAccount)] = Data(repeating: 77, count: 32) }
        let store = try fixture.makeStore()
        #expect(try store.delete(authority: .confirmedByUser) == .deleted)
        #expect(try store.delete(authority: .confirmedByUser) == .alreadyAbsent)
        #expect(fixture.backend.snapshot().items.count == 1)
        #expect(fixture.backend.snapshot().items[PersistentKeyBackend.index(other.service, otherAccount)] != nil)
        let query = try #require(fixture.backend.snapshot().lastDelete)
        #expect(query[kSecAttrAccount as String] as? String == fixture.account)
        #expect(query[kSecAttrService as String] as? String == fixture.namespace.service)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecUseAuthenticationUI as String] as! CFString == kSecUseAuthenticationUIFail)
    }

    @Test
    func failedDeletionPreservesKeyAndMalformedKeyNeedsExplicitDeletion() throws {
        let fixture = PersistentKeyFixture()
        let malformed = Data(count: 2)
        fixture.insert(malformed)
        let store = try fixture.makeStore()
        fixture.backend.configure { $0.deleteStatus = errSecInteractionNotAllowed }
        #expect(throws: ScribePersistentMemoryKeyError.locked) { try store.delete(authority: .confirmedByUser) }
        #expect(fixture.backend.snapshot().items.values.first == malformed)
        fixture.backend.configure { $0.deleteStatus = errSecSuccess }
        #expect(try store.delete(authority: .confirmedByUser) == .deleted)
        #expect(fixture.backend.snapshot().items.isEmpty)
    }

    @Test
    func namespaceRemainsStableAndIsolatesBundleInstallationAndStorageDomain() throws {
        let fixture = PersistentKeyFixture()
        let same = try ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: fixture.namespace.applicationBundleIdentifier,
            installationID: fixture.namespace.installationID, storageDomainID: fixture.namespace.storageDomainID)
        #expect(same == fixture.namespace)
        let variants = [
            try ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: "com.example.KeyFixture.debug", installationID: same.installationID, storageDomainID: same.storageDomainID),
            try ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: same.applicationBundleIdentifier, installationID: UUID(), storageDomainID: same.storageDomainID),
            try ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: same.applicationBundleIdentifier, installationID: same.installationID, storageDomainID: UUID())
        ]
        fixture.insert(fixture.generatedKey)
        for variant in variants {
            let other = try fixture.makeStore(namespace: variant)
            #expect(throws: ScribePersistentMemoryKeyError.notFound) { try other.keyData() }
            #expect(try other.provision(authority: .confirmedByUser) == .created)
        }
        #expect(fixture.backend.snapshot().items.count == 4)
        #expect(try fixture.makeStore(namespace: same).keyData() == fixture.generatedKey)
    }

    @Test
    func normalizedFilePathBindsKeyIdentityAndOtherPathCannotDeleteItsKey() throws {
        let fixture = PersistentKeyFixture()
        let first = try fixture.makeStore()
        _ = try first.provision(authority: .confirmedByUser)
        fixture.files.data = Data("ciphertext for first store".utf8)
        let otherFiles = PersistentKeyFiles(events: fixture.events)
        let other = try KeychainScribePersistentMemoryKeyStore(namespace: fixture.namespace,
            storeURL: URL(fileURLWithPath: "/synthetic-key-tests/other.json"), backend: fixture.backend, fileAccess: otherFiles)
        #expect(other.keychainAccount != first.keychainAccount)
        #expect(try other.delete(authority: .confirmedByUser) == .alreadyAbsent)
        #expect(try first.keyData() == fixture.generatedKey)
        #expect(try other.provision(authority: .confirmedByUser) == .created)
        #expect(try first.keyData() == fixture.generatedKey)
        let normalized = try fixture.makeStore(url: URL(fileURLWithPath: "/synthetic-key-tests/unused/../memory.json"))
        #expect(normalized.keychainAccount == first.keychainAccount)
        #expect(first.keychainAccount.count == 64)
        #expect(!first.keychainAccount.contains("synthetic") && !first.keychainAccount.contains(fixture.namespace.installationID.uuidString))
    }

    @Test
    func deleteAndReprovisionInvalidatesOldSaveAndReadEvenBeforeFirstFileExists() throws {
        let fixture = PersistentKeyFixture()
        fixture.files.allowsMemoryWrites = true
        let keyStore = try fixture.makeStore()
        _ = try keyStore.provision(authority: .confirmedByUser)
        let authority = try PersistentKeyMemoryAuthority()
        let access = try authority.access()
        let memory = ScribePersistentMemoryStore(url: URL(fileURLWithPath: "/synthetic-key-tests/memory.json"),
            keyProvider: keyStore, identityResolver: authority.resolver, policy: { authority.policy },
            clock: { authority.now }, fileAccess: fixture.files)
        let record = ScribeSessionMemoryRecord(id: UUID(), scopeKey: access.conversation.memoryKey, text: "Synthetic fact",
            topics: ["test"], provenance: .explicitUser(statementID: UUID()),
            origin: .init(actionID: access.contextAction.actionID, captureID: access.contextAction.captureID),
            createdAt: authority.now, expiresAt: authority.now + 600, supersedesRecordID: nil)
        let oldProposal = try memory.beginSave(record, for: access)
        let emptyRead = try memory.read(for: access)
        #expect(try keyStore.delete(authority: .confirmedByUser) == .deleted)
        #expect(throws: ScribePersistentMemoryError.keyUnavailable) { try memory.revalidateRead(emptyRead, for: access) }
        fixture.backend.configure { $0.randomResult = .init(status: errSecSuccess, data: Data(repeating: 8, count: 32)) }
        #expect(try keyStore.provision(authority: .confirmedByUser) == .created)
        #expect(throws: ScribePersistentMemoryError.staleToken) { try memory.revalidateRead(emptyRead, for: access) }
        #expect(throws: ScribePersistentMemoryError.staleToken) { try memory.completeSave(oldProposal, decision: .confirmedByUser, for: access) }
        #expect(fixture.files.data == nil)
        let freshProposal = try memory.beginSave(record, for: access)
        try memory.completeSave(freshProposal, decision: .confirmedByUser, for: access)
        let populatedRead = try memory.read(for: access)
        #expect(populatedRead.records == [record])
        fixture.backend.configure { $0.copyOverride = .init(status: errSecInteractionNotAllowed, data: nil) }
        #expect(throws: ScribePersistentMemoryError.keyUnavailable) { try memory.revalidateRead(populatedRead, for: access) }
    }

    @Test
    func invalidNamespaceAndNonfileURLCannotEstablishKeyAuthority() throws {
        for name in ["", "raw conversation title", ".com", "com..app", "com.app/secret", String(repeating: "x", count: 256) + ".app"] {
            #expect(throws: ScribePersistentMemoryKeyError.invalidNamespace) {
                try ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: name, installationID: UUID(), storageDomainID: UUID())
            }
        }
        let fixture = PersistentKeyFixture()
        #expect(throws: ScribePersistentMemoryKeyError.invalidStoreURL) {
            try KeychainScribePersistentMemoryKeyStore(namespace: fixture.namespace, storeURL: URL(string: "https://example.invalid/memory")!,
                                                       backend: fixture.backend, fileAccess: fixture.files)
        }
        #expect(fixture.events.values.isEmpty)
    }
}

private final class PersistentKeyEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
}

@MainActor
private final class PersistentKeyFiles: ScribePersistentMemoryFileAccess {
    let events: PersistentKeyEvents
    var data: Data?
    var readError: ScribePersistentMemoryError?
    var lockError: ScribePersistentMemoryError?
    var allowsMemoryWrites = false
    init(events: PersistentKeyEvents) { self.events = events }
    func withExclusiveLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        if let lockError { throw lockError }
        events.append("lock")
        defer { events.append("unlock") }
        return try operation()
    }
    func read(at url: URL, maximumBytes: Int) throws -> Data? {
        events.append("read-file")
        if let readError { throw readError }
        if let data, data.count > maximumBytes { throw ScribePersistentMemoryError.capacityExceeded }
        return data
    }
    func writeAtomically(_ data: Data, to url: URL) throws {
        guard allowsMemoryWrites else {
            Issue.record("Key lifecycle must not write encrypted store data")
            throw ScribePersistentMemoryError.ioFailure
        }
        self.data = data
    }
}

private final class PersistentKeyBackend: ScribePersistentMemorySecurityBackend, @unchecked Sendable {
    struct State {
        var items: [String: Data] = [:]
        var copyOverride: ScribePersistentMemorySecurityDataResult?
        var randomResult = ScribePersistentMemorySecurityDataResult(status: errSecSuccess, data: Data(repeating: 7, count: 32))
        var addStatus = errSecSuccess
        var deleteStatus = errSecSuccess
        var insertDuringAdd: Data?
        var addCount = 0
        var deleteCount = 0
        var randomCount = 0
        var lastAdd: [String: Any]?
        var lastCopy: [String: Any]?
        var lastDelete: [String: Any]?
    }
    private let lock = NSLock()
    private var state = State()
    let events: PersistentKeyEvents
    init(events: PersistentKeyEvents) { self.events = events }
    func configure(_ operation: (inout State) -> Void) { lock.withLock { operation(&state) } }
    func snapshot() -> State { lock.withLock { state } }
    static func index(_ service: String, _ account: String) -> String { service + "|" + account }
    private func index(_ query: [String: Any]) -> String {
        Self.index(query[kSecAttrService as String] as! String, query[kSecAttrAccount as String] as! String)
    }
    func copy(_ query: [String: Any]) -> ScribePersistentMemorySecurityDataResult {
        events.append("copy")
        return lock.withLock {
            state.lastCopy = query
            if let result = state.copyOverride { return result }
            guard let data = state.items[index(query)] else { return .init(status: errSecItemNotFound, data: nil) }
            return .init(status: errSecSuccess, data: data)
        }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        events.append("add")
        return lock.withLock {
            state.addCount += 1
            state.lastAdd = attributes
            let key = index(attributes)
            if let injected = state.insertDuringAdd { state.items[key] = injected }
            if state.addStatus != errSecSuccess { return state.addStatus }
            if state.insertDuringAdd == nil {
                guard state.items[key] == nil else { return errSecDuplicateItem }
                state.items[key] = attributes[kSecValueData as String] as? Data
            }
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        events.append("delete")
        return lock.withLock {
            state.deleteCount += 1
            state.lastDelete = query
            guard state.deleteStatus == errSecSuccess else { return state.deleteStatus }
            return state.items.removeValue(forKey: index(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
    func randomKeyData() -> ScribePersistentMemorySecurityDataResult {
        events.append("random")
        return lock.withLock { state.randomCount += 1; return state.randomResult }
    }
}

@MainActor
private final class PersistentKeyFixture {
    let events = PersistentKeyEvents()
    let generatedKey = Data(repeating: 7, count: 32)
    let namespace = try! ScribePersistentMemoryKeyNamespace(applicationBundleIdentifier: "com.example.KeyFixture",
        installationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        storageDomainID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!)
    lazy var backend = PersistentKeyBackend(events: events)
    lazy var files = PersistentKeyFiles(events: events)
    var account: String { try! makeStore().keychainAccount }
    func insert(_ data: Data) { backend.configure { $0.items[PersistentKeyBackend.index(namespace.service, account)] = data } }
    func makeStore(namespace: ScribePersistentMemoryKeyNamespace? = nil,
                   url: URL = URL(fileURLWithPath: "/synthetic-key-tests/memory.json")) throws -> KeychainScribePersistentMemoryKeyStore {
        try .init(namespace: namespace ?? self.namespace, storeURL: url, backend: backend, fileAccess: files)
    }
}

@MainActor
private final class PersistentKeyMemoryAuthority: ScribeConversationIdentityAdapter {
    static let bundleID = "com.example.KeyMemoryFixture"
    let now = Date(timeIntervalSince1970: 50_000)
    var policy = ScribeContextPolicySnapshot()
    let registration = ScribeConversationAdapterRegistration(adapterID: .init(rawValue: "key-memory-fixture")!, schemaVersion: 1,
        source: .browserIntegration, hostBundleIdentifier: PersistentKeyMemoryAuthority.bundleID, applicationID: .init(rawValue: "fixture-support")!)
    let binding = ScribeConversationActionBinding(actionID: UUID(),
        process: .init(processIdentifier: 91, bundleIdentifier: PersistentKeyMemoryAuthority.bundleID,
                       bundleURL: URL(fileURLWithPath: "/Applications/Fixture.app"), incarnation: UUID()),
        windowIncarnation: UUID(), tabIncarnation: UUID(), navigationRevision: UUID())
    lazy var resolver = try! ScribeConversationIdentityResolver(adapters: [self])
    init() throws {
        let scope = ScribeContextAccessScope.application(bundleIdentifier: Self.bundleID)
        let window = ScribeContextGrantWindow(acceptedAt: now - 100, expiresAt: now + 10_000)
        policy.isEnabled = true
        policy.captureGrants = [.init(id: UUID(), scope: scope, categories: [.persistentMemory, .sessionMemory], window: window)]
        policy.retentionGrants = [.init(id: UUID(), scope: scope, categories: [.persistentMemory, .sessionMemory],
            destination: .persistentMemory, maximumRetentionInterval: 7_200, window: window)]
    }
    func access() throws -> ScribeSessionMemoryAccess {
        guard case let .verified(identity) = resolver.resolve(adapterID: registration.adapterID, for: binding) else {
            throw ScribePersistentMemoryError.identityChanged
        }
        return .init(conversation: identity, currentBinding: binding,
            contextAction: .init(actionID: binding.actionID, captureID: UUID(),
                target: .init(processIdentifier: binding.process.processIdentifier, bundleIdentifier: Self.bundleID),
                opaqueSurfaceID: identity.memoryKey.opaqueValue, eligibility: .eligible))
    }
    func evidence(for binding: ScribeConversationActionBinding) -> ScribeConversationIdentityEvidence? {
        .init(adapterID: registration.adapterID, schemaVersion: 1, source: .browserIntegration, binding: self.binding,
            confidence: .verifiedStableIdentifiers, privacyState: .regular, applicationID: registration.applicationID,
            accountID: .init(rawValue: "account-a"), workspaceID: .identified(.init(rawValue: "workspace-a")!),
            projectID: .identified(.init(rawValue: "project-a")!), conversationID: .init(rawValue: "thread-a"))
    }
}
