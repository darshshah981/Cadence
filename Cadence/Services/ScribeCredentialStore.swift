import Foundation
import Security

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
            kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
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
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
