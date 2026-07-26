import Foundation
import Security
import Testing
@testable import Cadence

struct ScribeCredentialStoreTests {
    @Test
    func productionQueriesUseTheProvisioningIndependentMacKeychain() {
        let attributes = ScribeSecurityItemExecutor.acceptedAttributes(
            service: KeychainScribeCredentialVault.candidateService,
            account: "opaque"
        )

        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test
    func candidateAndInheritedServicesAreExactlyIsolated() async throws {
        let executor = U5SecurityExecutor()
        let vault = KeychainScribeCredentialVault(executor: executor)
        let staged = try await vault.stageCandidate("candidate-key")
        #expect(staged.domain == .candidate)
        #expect(try await vault.load(staged) == "candidate-key")

        let inherited = ScribeStoredCredentialReference(
            domain: .inherited,
            opaqueReference: staged.opaqueReference
        )
        #expect(try await vault.load(inherited) == nil)
        try await vault.delete(inherited)
        #expect(try await vault.load(staged) == "candidate-key")
        #expect(try await vault.candidateReferences() == [staged])
    }

    @Test
    func acceptedAccessibilityAndSynchronizationAttributesRemainExact() {
        let attributes = ScribeSecurityItemExecutor.acceptedAttributes(
            service: KeychainScribeCredentialVault.candidateService,
            account: "opaque"
        )
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)
        #expect(attributes[kSecAttrAccessible as String] as! CFString
            == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    @Test @MainActor
    func productionVaultChainExecutesSecurityBackendOffMainAndSerially() async throws {
        let backend = RecordingSecurityBackend()
        let vault = KeychainScribeCredentialVault(
            executor: ScribeSecurityItemExecutor(backend: backend)
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    _ = try await vault.stageCandidate("key-\(index)")
                }
            }
            try await group.waitForAll()
        }

        #expect(backend.maximumConcurrentCalls == 1)
        #expect(backend.observedMainThread == false)
        #expect(try await vault.candidateReferences().count == 8)
    }

    @Test
    func reconciliationEnumeratesCandidatesOnlyAndProtectsV2PlusLegacyUnion() async throws {
        let library = U5LibraryStore()
        let legacy = U5LegacyStore()
        let ledger = U5LedgerStore()
        let vault = U5Vault()
        let authority = ScribeProviderConsentAuthority()
        let receipt = await authority.issueEphemeral(
            providerKind: .openAIDirect,
            recipientOrigin: "https://api.openai.com",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies,
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let activeReference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "active")
        )
        let orphanReference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "orphan")
        )
        let configuration = try U5Fixtures.configuration(
            kind: .openAIDirect, model: "gpt-test", receipt: receipt,
            reference: activeReference
        )
        library.result = .valid(ScribeProviderLibrary(
            revision: 1, configurations: [configuration], activeConfigurationID: configuration.id
        ))
        let inheritedReference = ScribeCredentialReference(rawValue: "legacy-protected")
        legacy.result = .valid(try ScribeProviderConfiguration.deepSeek(
            credentialReference: inheritedReference, acceptedAt: Date()
        ))
        await vault.insert(activeReference)
        await vault.insert(orphanReference)
        let reconciler = ScribeCredentialReconciler(
            libraryStore: library, legacyStore: legacy, ledgerStore: ledger, vault: vault
        )
        #expect(await reconciler.protectedReferences() == .available([
            activeReference,
            ScribeStoredCredentialReference(domain: .inherited, opaqueReference: inheritedReference)
        ]))
        try await reconciler.reconcile()
        #expect(await vault.staged == [activeReference])
    }
}

private final class RecordingSecurityBackend: ScribeSecurityItemBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: [String: Data]] = [:]
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var observedMainThread = false

    func add(_ attributes: [String: Any]) throws {
        enter()
        defer { leave() }
        guard let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else {
            throw ScribeCredentialStoreError.invalidStoredValue
        }
        lock.withLock { values[service, default: [:]][account] = data }
    }

    func copy(_ query: [String: Any]) throws -> Any? {
        enter()
        defer { leave() }
        guard let service = query[kSecAttrService as String] as? String else { return nil }
        if let account = query[kSecAttrAccount as String] as? String {
            return lock.withLock { values[service]?[account] }
        }
        return lock.withLock {
            values[service, default: [:]].keys.map { [kSecAttrAccount as String: $0] }
        }
    }

    func delete(_ query: [String: Any]) throws {
        enter()
        defer { leave() }
        guard let service = query[kSecAttrService as String] as? String,
              let account = query[kSecAttrAccount as String] as? String else { return }
        lock.withLock { values[service]?[account] = nil }
    }

    private func enter() {
        lock.withLock {
            activeCalls += 1
            maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
            observedMainThread = observedMainThread || Thread.isMainThread
        }
        Thread.sleep(forTimeInterval: 0.002)
    }

    private func leave() { lock.withLock { activeCalls -= 1 } }
}

actor U5SecurityExecutor: ScribeSecurityItemExecuting {
    private var values: [String: [String: Data]] = [:]
    var operations: [String] = []

    func add(service: String, account: String, value: Data) {
        operations.append("add:\(service):\(account)")
        values[service, default: [:]][account] = value
    }

    func load(service: String, account: String) -> Data? {
        operations.append("load:\(service):\(account)")
        return values[service]?[account]
    }

    func delete(service: String, account: String) {
        operations.append("delete:\(service):\(account)")
        values[service]?[account] = nil
    }

    func accounts(service: String) -> Set<String> {
        operations.append("accounts:\(service)")
        return Set(values[service]?.keys ?? [:].keys)
    }
}
