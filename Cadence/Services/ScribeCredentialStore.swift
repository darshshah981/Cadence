import Foundation
import Security

enum ScribeCredentialAccessibilityDecision {
    /// Accepted in docs/adaptive-scribe-release-evidence.md for this compatibility release.
    static let inheritedAfterFirstUnlockThisDeviceOnlyAccepted = true
}

protocol ScribeCredentialStoring: AnyObject {
    func stage(_ credential: String) throws -> ScribeCredentialReference
    func load(reference: ScribeCredentialReference) throws -> String?
    func delete(reference: ScribeCredentialReference) throws
    func allReferences() throws -> Set<ScribeCredentialReference>
}

enum ScribeCredentialStoreError: Error, Equatable {
    case invalidCredential
    case keychain(OSStatus)
    case invalidStoredValue
}

final class KeychainScribeCredentialStore: ScribeCredentialStoring, @unchecked Sendable {
    static let service = "com.darshshah.Cadence.scribe-provider"

    func stage(_ credential: String) throws -> ScribeCredentialReference {
        guard !credential.isEmpty,
              !credential.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ScribeCredentialStoreError.invalidCredential
        }
        let reference = ScribeCredentialReference(rawValue: UUID().uuidString)
        var attributes = Self.addAttributes(reference: reference)
        attributes[kSecValueData as String] = Data(credential.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ScribeCredentialStoreError.keychain(status)
        }
        return reference
    }

    func load(reference: ScribeCredentialReference) throws -> String? {
        var query = Self.baseQuery(reference: reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw status == errSecSuccess
                ? ScribeCredentialStoreError.invalidStoredValue
                : ScribeCredentialStoreError.keychain(status)
        }
        return value
    }

    func delete(reference: ScribeCredentialReference) throws {
        let status = SecItemDelete(Self.baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ScribeCredentialStoreError.keychain(status)
        }
    }

    func allReferences() throws -> Set<ScribeCredentialReference> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw ScribeCredentialStoreError.keychain(status)
        }
        let dictionaries: [[String: Any]]
        if let array = result as? [[String: Any]] {
            dictionaries = array
        } else if let dictionary = result as? [String: Any] {
            dictionaries = [dictionary]
        } else {
            throw ScribeCredentialStoreError.invalidStoredValue
        }
        return Set(dictionaries.compactMap { attributes in
            (attributes[kSecAttrAccount as String] as? String)
                .map(ScribeCredentialReference.init(rawValue:))
        })
    }

    static func addAttributes(reference: ScribeCredentialReference) -> [String: Any] {
        var attributes = baseQuery(reference: reference)
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return attributes
    }

    private static func baseQuery(reference: ScribeCredentialReference) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }
}

protocol ScribeCredentialVaulting: Sendable {
    func stageCandidate(_ credential: String) async throws -> ScribeStoredCredentialReference
    func load(_ reference: ScribeStoredCredentialReference) async throws -> String?
    func delete(_ reference: ScribeStoredCredentialReference) async throws
    func candidateReferences() async throws -> Set<ScribeStoredCredentialReference>
}

protocol ScribeSecurityItemExecuting: Sendable {
    func add(service: String, account: String, value: Data) async throws
    func load(service: String, account: String) async throws -> Data?
    func delete(service: String, account: String) async throws
    func accounts(service: String) async throws -> Set<String>
}

protocol ScribeSecurityItemBackend: Sendable {
    func add(_ attributes: [String: Any]) throws
    func copy(_ query: [String: Any]) throws -> Any?
    func delete(_ query: [String: Any]) throws
}

struct SystemScribeSecurityItemBackend: ScribeSecurityItemBackend, @unchecked Sendable {
    func add(_ attributes: [String: Any]) throws {
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ScribeCredentialStoreError.keychain(status) }
    }

    func copy(_ query: [String: Any]) throws -> Any? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ScribeCredentialStoreError.keychain(status) }
        return result
    }

    func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ScribeCredentialStoreError.keychain(status)
        }
    }
}

actor ScribeSecurityItemExecutor: ScribeSecurityItemExecuting {
    private let backend: any ScribeSecurityItemBackend

    init(backend: any ScribeSecurityItemBackend = SystemScribeSecurityItemBackend()) {
        self.backend = backend
    }

    func add(service: String, account: String, value: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: value
        ]
        try backend.add(attributes)
    }

    func load(service: String, account: String) throws -> Data? {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard let result = try backend.copy(query) else { return nil }
        guard let data = result as? Data else { throw ScribeCredentialStoreError.invalidStoredValue }
        return data
    }

    func delete(service: String, account: String) throws {
        try backend.delete(Self.query(service: service, account: account))
    }

    func accounts(service: String) throws -> Set<String> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        guard let result = try backend.copy(query) else { return [] }
        let values = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return Set(values.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    static func acceptedAttributes(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

struct KeychainScribeCredentialVault: ScribeCredentialVaulting, Sendable {
    static let inheritedService = KeychainScribeCredentialStore.service
    static let candidateService = "com.darshshah.Cadence.scribe-provider-candidates"

    private let executor: any ScribeSecurityItemExecuting

    init(executor: any ScribeSecurityItemExecuting = ScribeSecurityItemExecutor()) {
        self.executor = executor
    }

    func stageCandidate(_ credential: String) async throws -> ScribeStoredCredentialReference {
        guard !credential.isEmpty,
              credential.utf8.count <= 16 * 1_024,
              !credential.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { throw ScribeCredentialStoreError.invalidCredential }
        let reference = ScribeStoredCredentialReference(
            domain: .candidate,
            opaqueReference: ScribeCredentialReference(rawValue: UUID().uuidString)
        )
        try await executor.add(
            service: Self.candidateService,
            account: reference.opaqueReference.rawValue,
            value: Data(credential.utf8)
        )
        return reference
    }

    func load(_ reference: ScribeStoredCredentialReference) async throws -> String? {
        guard let data = try await executor.load(
            service: service(for: reference.domain),
            account: reference.opaqueReference.rawValue
        ) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw ScribeCredentialStoreError.invalidStoredValue
        }
        return value
    }

    func delete(_ reference: ScribeStoredCredentialReference) async throws {
        try await executor.delete(
            service: service(for: reference.domain),
            account: reference.opaqueReference.rawValue
        )
    }

    func candidateReferences() async throws -> Set<ScribeStoredCredentialReference> {
        Set(try await executor.accounts(service: Self.candidateService).map {
            ScribeStoredCredentialReference(
                domain: .candidate,
                opaqueReference: ScribeCredentialReference(rawValue: $0)
            )
        })
    }

    private func service(for domain: ScribeCredentialStorageDomain) -> String {
        domain == .candidate ? Self.candidateService : Self.inheritedService
    }
}
