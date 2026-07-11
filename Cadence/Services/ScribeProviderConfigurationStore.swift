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
        guard library.configurations.allSatisfy(isValid) else { return .invalidConfiguration }
        return nil
    }

    private static func isValid(_ configuration: ScribeProviderLibraryConfiguration) -> Bool {
        let value = configuration.normalized()
        guard !value.displayName.isEmpty,
              value.displayName.utf8.count <= 256,
              !value.displayName.unicodeScalars.contains(where: isUnsupportedControl),
              (try? ScribeModelIdentifier(value.selectedModelID)) != nil,
              !value.credentialReference.rawValue.isEmpty,
              value.credentialReference.rawValue.utf8.count <= 256,
              !value.credentialReference.rawValue.unicodeScalars.contains(where: isUnsupportedControl),
              value.disclosureVersion > 0,
              value.acceptedAt <= value.lastValidatedAt else {
            return false
        }
        if let catalogID = value.catalogID {
            guard !catalogID.isEmpty,
                  catalogID.utf8.count <= ScribeProviderLibraryConfiguration.maximumCatalogIDUTF8Bytes,
                  !catalogID.unicodeScalars.contains(where: isUnsupportedControl) else {
                return false
            }
        }

        switch value.kind {
        case .deepSeek:
            return value.normalizedOrigin == "https://api.deepseek.com"
                && value.baseURL.absoluteString == "https://api.deepseek.com"
                && value.requestURL.absoluteString == "https://api.deepseek.com/chat/completions"
        case .openAIDirect:
            return value.normalizedOrigin == "https://api.openai.com"
                && value.baseURL.absoluteString == "https://api.openai.com"
                && value.requestURL.absoluteString == "https://api.openai.com/v1/responses"
        case .openRouter:
            return value.normalizedOrigin == "https://openrouter.ai"
                && value.baseURL.absoluteString == "https://openrouter.ai"
                && value.requestURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions"
        case .advanced:
            guard let endpoint = try? AdvancedScribeEndpoint(value.baseURL.absoluteString) else { return false }
            return endpoint.normalizedOrigin == value.normalizedOrigin
                && endpoint.normalizedBaseURL == value.baseURL
                && endpoint.requestURL == value.requestURL
        case .legacyLocal:
            return value.normalizedOrigin == "local://this-mac"
        }
    }

    private static func isUnsupportedControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}
