import CryptoKit
import Foundation
import OSLog
import Security

private let scribePersistentMemoryKeyLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ScribePersistentMemoryKeyStore"
)

enum ScribePersistentMemoryKeyError: Error, Equatable, Sendable {
    case invalidNamespace, invalidStoreURL, confirmationRequired
    case notFound, locked, unavailable, corrupt, randomGenerationFailed
    case encryptedStoreExists, storageUnavailable, keyChanged
    case securityFailure(OSStatus)
}

/// The owner must persist these identifiers before provisioning and supply the
/// same values after restart. No constructor generates a new installation or
/// storage-domain ID. The domain ID is not the encrypted manifest's revision ID.
struct ScribePersistentMemoryKeyNamespace: Equatable, Sendable {
    let applicationBundleIdentifier: String
    let installationID: UUID
    let storageDomainID: UUID

    init(applicationBundleIdentifier: String, installationID: UUID, storageDomainID: UUID) throws {
        try Self.validateApplicationBundleIdentifier(applicationBundleIdentifier)
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.installationID = installationID
        self.storageDomainID = storageDomainID
    }

    static func validateApplicationBundleIdentifier(_ applicationBundleIdentifier: String) throws {
        let parts = applicationBundleIdentifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, applicationBundleIdentifier.utf8.count <= 255,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
              }}) else { throw ScribePersistentMemoryKeyError.invalidNamespace }
    }

    var service: String { applicationBundleIdentifier + ".compose-memory.aes256.v1" }
    fileprivate func account(forNormalizedStorePath path: String) -> String {
        var material = Data("Cadence.Compose.MemoryKeyNamespace.v1".utf8)
        for field in [applicationBundleIdentifier, installationID.uuidString.lowercased(), storageDomainID.uuidString.lowercased(), path] {
            let bytes = Data(field.utf8)
            material.append(Data("\(bytes.count):".utf8))
            material.append(bytes)
        }
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }
}

/// Trusted confirmation code must supply this decision for the concrete local
/// installation/store. Decoding configuration or a memory record is not consent.
enum ScribePersistentMemoryKeyProvisioningAuthority: Equatable, Sendable {
    case notConfirmed, confirmedByUser
}

enum ScribePersistentMemoryKeyDeletionAuthority: Equatable, Sendable {
    case notConfirmed, confirmedByUser
}

enum ScribePersistentMemoryKeyProvisioningResult: Equatable, Sendable { case created, alreadyPresent }
enum ScribePersistentMemoryKeyDeletionResult: Equatable, Sendable { case deleted, alreadyAbsent }

/// Successful reads with nil/non-data values are corrupt, not missing. Keeping
/// OSStatus typed avoids passing raw Security error strings into diagnostics.
struct ScribePersistentMemorySecurityDataResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol ScribePersistentMemorySecurityBackend: Sendable {
    func copy(_ query: [String: Any]) -> ScribePersistentMemorySecurityDataResult
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
    func randomKeyData() -> ScribePersistentMemorySecurityDataResult
}

struct SystemScribePersistentMemorySecurityBackend: ScribePersistentMemorySecurityBackend {
    func copy(_ query: [String: Any]) -> ScribePersistentMemorySecurityDataResult {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return .init(status: status, data: value as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }

    func randomKeyData() -> ScribePersistentMemorySecurityDataResult {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        return .init(status: status, data: status == errSecSuccess ? data : nil)
    }
}

/// This immutable provider never caches keys, silently provisions, rotates, or
/// repairs them. Its Sendable backend handles synchronous Security operations;
/// the non-Sendable file collaborator is used only by MainActor lifecycle calls.
/// No initialization IO, host Keychain calls, or runtime wiring occur implicitly.
final class KeychainScribePersistentMemoryKeyStore: ScribePersistentMemoryKeyProviding, @unchecked Sendable {
    let namespace: ScribePersistentMemoryKeyNamespace
    let keychainAccount: String
    private let storeURL: URL
    private let backend: any ScribePersistentMemorySecurityBackend
    private let files: any ScribePersistentMemoryFileAccess

    @MainActor
    init(namespace: ScribePersistentMemoryKeyNamespace, storeURL: URL,
         backend: any ScribePersistentMemorySecurityBackend = SystemScribePersistentMemorySecurityBackend(),
         fileAccess: (any ScribePersistentMemoryFileAccess)? = nil) throws {
        guard storeURL.isFileURL, !storeURL.hasDirectoryPath else { throw ScribePersistentMemoryKeyError.invalidStoreURL }
        self.namespace = namespace
        self.storeURL = storeURL.standardizedFileURL
        self.keychainAccount = namespace.account(forNormalizedStorePath: storeURL.standardizedFileURL.path)
        self.backend = backend
        self.files = fileAccess ?? SystemScribePersistentMemoryFileAccess()
    }

    /// Read-only KeyProviding seam. A missing/locked/malformed key never starts
    /// provisioning. The encrypted store remains responsible for authenticating
    /// its manifest; a well-formed but incorrect key is never replaced here.
    func keyData() throws -> Data {
        var query = accessQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = backend.copy(query)
        guard result.status == errSecSuccess else { throw mappedError(result.status) }
        guard let data = result.data, data.count == 32 else { throw ScribePersistentMemoryKeyError.corrupt }
        return data
    }

    /// Provision only for a confirmed, absent data store. The shared file lock
    /// covers the absence check and Keychain add so cooperating store writers
    /// cannot create encrypted data between them. Existing bytes of any kind
    /// block provisioning; file/key recovery needs a separate explicit workflow.
    @MainActor
    func provision(authority: ScribePersistentMemoryKeyProvisioningAuthority) throws -> ScribePersistentMemoryKeyProvisioningResult {
        guard authority == .confirmedByUser else { throw ScribePersistentMemoryKeyError.confirmationRequired }
        return try files.withExclusiveLock(at: storeURL) {
            try requireAbsentStore()
            do {
                _ = try keyData()
                return .alreadyPresent
            } catch ScribePersistentMemoryKeyError.notFound {
                // Only true absence may provision. Locked/unavailable/corrupt
                // data is preserved; there is deliberately no update operation.
            }
            let generated = backend.randomKeyData()
            guard generated.status == errSecSuccess, let data = generated.data, data.count == 32 else {
                throw ScribePersistentMemoryKeyError.randomGenerationFailed
            }
            var attributes = itemIdentity()
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            attributes[kSecValueData as String] = data
            let status = backend.add(attributes)
            if status == errSecDuplicateItem {
                _ = try keyData()
                return .alreadyPresent
            }
            guard status == errSecSuccess else { throw mappedError(status) }
            guard try keyData() == data else { throw ScribePersistentMemoryKeyError.keyChanged }
            return .created
        }
    }

    /// Key deletion is separate from conversation forgetting. It requires a
    /// confirmed absent data file, preventing accidental loss of decryption for
    /// a retained store. This does not erase backups or already returned copies.
    @MainActor
    func delete(authority: ScribePersistentMemoryKeyDeletionAuthority) throws -> ScribePersistentMemoryKeyDeletionResult {
        guard authority == .confirmedByUser else { throw ScribePersistentMemoryKeyError.confirmationRequired }
        return try files.withExclusiveLock(at: storeURL) {
            try requireAbsentStore()
            let status = backend.delete(accessQuery())
            if status == errSecItemNotFound { return .alreadyAbsent }
            guard status == errSecSuccess else { throw mappedError(status) }
            return .deleted
        }
    }

    private func itemIdentity() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace.service,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func accessQuery() -> [String: Any] {
        var query = itemIdentity()
        // Query-only: reads/deletions fail rather than prompting in a callback.
        // Explicit provisioning uses SecItemAdd attributes, not query options.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        return query
    }

    @MainActor
    private func requireAbsentStore() throws {
        do {
            guard try files.read(at: storeURL, maximumBytes: 1) == nil else {
                throw ScribePersistentMemoryKeyError.encryptedStoreExists
            }
        } catch ScribePersistentMemoryError.capacityExceeded {
            throw ScribePersistentMemoryKeyError.encryptedStoreExists
        } catch let error as ScribePersistentMemoryKeyError { throw error }
        catch { throw ScribePersistentMemoryKeyError.storageUnavailable }
    }

    private func mappedError(_ status: OSStatus) -> ScribePersistentMemoryKeyError {
        switch status {
        case errSecItemNotFound: return .notFound
        // These statuses indicate an unavailable unlocked/authenticated context;
        // Security does not always identify physical Keychain lock separately.
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .locked
        case errSecNotAvailable: return .unavailable
        case errSecDecode: return .corrupt
        default: return .securityFailure(status)
        }
    }
}
