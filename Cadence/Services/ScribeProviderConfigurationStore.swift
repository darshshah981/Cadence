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
