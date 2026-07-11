import Foundation

protocol ScribeProviderConfigurationPersisting: AnyObject {
    func load() -> ScribeProviderConfigurationLoadResult
    func save(_ configuration: ScribeProviderConfiguration?) throws
}

final class ScribeProviderConfigurationStore: ScribeProviderConfigurationPersisting {
    static let defaultKey = "Cadence.scribeProviderConfiguration"

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        key: String = ScribeProviderConfigurationStore.defaultKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() -> ScribeProviderConfigurationLoadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let envelope = try? decoder.decode(ScribeProviderConfigurationEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard envelope.schemaVersion <= ScribeProviderConfigurationEnvelope.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard envelope.schemaVersion == ScribeProviderConfigurationEnvelope.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        return .valid(envelope.configuration)
    }

    func save(_ configuration: ScribeProviderConfiguration?) throws {
        guard let configuration else {
            defaults.removeObject(forKey: key)
            return
        }
        let envelope = ScribeProviderConfigurationEnvelope(configuration: configuration)
        defaults.set(try encoder.encode(envelope), forKey: key)
    }
}

enum StrictPersistenceError: Error, Equatable {
    case invalidValue
    case semanticReadbackFailed
}

final class ScribeProviderLibraryStore {
    static let defaultKey = CadenceDurablePreferenceKeys.providerLibrary

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        key: String = ScribeProviderLibraryStore.defaultKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() -> ScribeProviderLibraryLoadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let envelope = try? decoder.decode(ScribeProviderLibraryEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard envelope.schemaVersion <= ScribeProviderLibraryEnvelope.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard envelope.schemaVersion == ScribeProviderLibraryEnvelope.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        if let rejection = Self.validate(envelope.library) {
            return .rejected(rejection)
        }
        return .valid(envelope.library.normalized())
    }

    func save(_ library: ScribeProviderLibrary) throws {
        guard Self.validate(library) == nil else { throw StrictPersistenceError.invalidValue }
        let normalized = library.normalized()
        let previous = defaults.data(forKey: key)
        defaults.set(try encoder.encode(ScribeProviderLibraryEnvelope(library: normalized)), forKey: key)
        guard case let .valid(readback) = load(), readback.semanticallyEquals(normalized) else {
            restore(previous)
            throw StrictPersistenceError.semanticReadbackFailed
        }
    }

    func referencedCredentials() -> ScribeCredentialReferenceSet {
        guard case let .valid(library) = load() else { return .unavailable }
        return .available(Set(library.configurations.map(\.credentialReference)))
    }

    private func restore(_ previous: Data?) {
        if let previous {
            defaults.set(previous, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func validate(_ library: ScribeProviderLibrary) -> ScribeProviderLibraryRejection? {
        guard library.revision >= 0 else { return .invalidConfiguration }
        guard Set(library.configurations.map(\.id)).count == library.configurations.count else {
            return .duplicateConfigurationID
        }
        guard Set(library.configurations.map(\.kind)).count == library.configurations.count else {
            return .duplicateProviderKind
        }
        guard Set(library.configurations.map(\.credentialReference)).count == library.configurations.count else {
            return .duplicateCredentialReference
        }
        if let activeID = library.activeConfigurationID {
            guard let active = library.configurations.first(where: { $0.id == activeID }) else {
                return .invalidActiveConfigurationID
            }
            guard active.isEnabled else { return .disabledActiveConfiguration }
        }
        guard library.configurations.allSatisfy(ScribeProviderLibraryConfigurationValidator.isValid)
        else { return .invalidConfiguration }
        return nil
    }
}

protocol ScribeProviderLibraryPersisting: AnyObject {
    func load() -> ScribeProviderLibraryLoadResult
    func save(_ library: ScribeProviderLibrary) throws
    func referencedCredentials() -> ScribeCredentialReferenceSet
}

extension ScribeProviderLibraryStore: ScribeProviderLibraryPersisting {}

enum ScribeCleanupLedgerLoadResult: Equatable, Sendable {
    case absent
    case valid(ScribeCredentialCleanupLedger)
    case rejected
}

struct ScribeCredentialCleanupLedger: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumEntries = 128

    let schemaVersion: Int
    let revision: Int
    let references: Set<ScribeStoredCredentialReference>

    init(
        schemaVersion: Int = currentSchemaVersion,
        revision: Int,
        references: Set<ScribeStoredCredentialReference>
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.references = references
    }
}

protocol ScribeCredentialCleanupLedgerPersisting: AnyObject {
    func load() -> ScribeCleanupLedgerLoadResult
    func save(_ ledger: ScribeCredentialCleanupLedger?) throws
}

final class ScribeCredentialCleanupLedgerStore: ScribeCredentialCleanupLedgerPersisting {
    static let defaultKey = "Cadence.scribeCredentialCleanupLedger"
    private let bytes: any ScribeCleanupLedgerBytesPersisting
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.bytes = UserDefaultsScribeCleanupLedgerBytes(defaults: defaults)
        self.key = key
    }

    init(bytes: any ScribeCleanupLedgerBytesPersisting, key: String = defaultKey) {
        self.bytes = bytes
        self.key = key
    }

    func load() -> ScribeCleanupLedgerLoadResult {
        guard let data = bytes.data(forKey: key) else { return .absent }
        guard let ledger = try? JSONDecoder().decode(ScribeCredentialCleanupLedger.self, from: data),
              Self.isValid(ledger) else { return .rejected }
        return .valid(ledger)
    }

    func save(_ ledger: ScribeCredentialCleanupLedger?) throws {
        if let ledger, !Self.isValid(ledger) { throw StrictPersistenceError.invalidValue }
        if case .rejected = load() { throw ScribeProviderConnectionError.retainedStoreUnreadable }
        let previous = bytes.data(forKey: key)
        do {
            if let ledger {
                try bytes.set(try JSONEncoder().encode(ledger), forKey: key)
                guard load() == .valid(ledger) else { throw StrictPersistenceError.semanticReadbackFailed }
            } else {
                try bytes.remove(forKey: key)
                guard load() == .absent else { throw StrictPersistenceError.semanticReadbackFailed }
            }
        } catch {
            try? restore(previous)
            throw error
        }
    }

    private func restore(_ previous: Data?) throws {
        if let previous { try bytes.set(previous, forKey: key) }
        else { try bytes.remove(forKey: key) }
    }

    private static func isValid(_ ledger: ScribeCredentialCleanupLedger) -> Bool {
        ledger.schemaVersion == ScribeCredentialCleanupLedger.currentSchemaVersion
            && ledger.revision >= 0
            && ledger.references.count <= ScribeCredentialCleanupLedger.maximumEntries
            && ledger.references.allSatisfy {
                !$0.opaqueReference.rawValue.isEmpty
                    && $0.opaqueReference.rawValue.utf8.count <= 256
                    && !$0.opaqueReference.rawValue.unicodeScalars.contains(where: {
                        $0.value < 0x20 || $0.value == 0x7F
                    })
            }
    }
}

protocol ScribeCleanupLedgerBytesPersisting: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String) throws
    func remove(forKey key: String) throws
}

private final class UserDefaultsScribeCleanupLedgerBytes: ScribeCleanupLedgerBytesPersisting {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data, forKey key: String) throws { defaults.set(data, forKey: key) }
    func remove(forKey key: String) throws { defaults.removeObject(forKey: key) }
}
