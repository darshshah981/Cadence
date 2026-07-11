import Foundation

final class ApplicationConfigurationStore {
    static let defaultKey = CadenceDurablePreferenceKeys.applicationConfigurations

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        key: String = ApplicationConfigurationStore.defaultKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
        self.decoder = decoder
    }

    var safeResolution: SafeScribeGuidanceResolution { .generalNeutral }

    func load() -> ApplicationConfigurationLoadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let envelope = try? decoder.decode(ApplicationConfigurationEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard envelope.schemaVersion <= ApplicationConfigurationEnvelope.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard envelope.schemaVersion == ApplicationConfigurationEnvelope.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        if let rejection = Self.validate(envelope.library) { return .rejected(rejection) }
        return .valid(envelope.library.normalized())
    }

    func save(_ library: ApplicationConfigurationLibrary) throws {
        guard Self.validate(library) == nil else { throw StrictPersistenceError.invalidValue }
        let normalized = library.normalized()
        let previous = defaults.data(forKey: key)
        defaults.set(try encoder.encode(ApplicationConfigurationEnvelope(library: normalized)), forKey: key)
        guard case let .valid(readback) = load(), readback.semanticallyEquals(normalized) else {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            throw StrictPersistenceError.semanticReadbackFailed
        }
    }

    private static func validate(_ library: ApplicationConfigurationLibrary) -> ApplicationConfigurationRejection? {
        guard library.revision >= 0 else { return .invalidConfiguration }
        let configurations = library.configurations.map { $0.normalized() }
        guard Set(configurations.map(\.id)).count == configurations.count else {
            return .duplicateConfigurationID
        }
        let references = configurations.map {
            ApplicationReferenceKey(
                bundleIdentifier: $0.application.bundleIdentifier,
                bundleURL: $0.application.lastKnownBundleURL.standardizedFileURL
            )
        }
        guard Set(references).count == references.count else { return .duplicateApplicationReference }
        guard Set(configurations.map(\.application.id)).count == configurations.count else {
            return .duplicateApplicationReference
        }
        guard configurations.allSatisfy(isValid) else { return .invalidConfiguration }
        return nil
    }

    private static func isValid(_ configuration: ApplicationConfiguration) -> Bool {
        let reference = configuration.application.normalized()
        guard configuration.revision >= 1,
              reference.schemaVersion == ApplicationReference.currentSchemaVersion,
              !reference.bundleIdentifier.isEmpty,
              reference.bundleIdentifier.utf8.count <= 255,
              !reference.bundleIdentifier.unicodeScalars.contains(where: isUnsupportedControl),
              !reference.lastKnownDisplayName.isEmpty,
              reference.lastKnownDisplayName.utf8.count <= 256,
              !reference.lastKnownDisplayName.unicodeScalars.contains(where: isUnsupportedControl),
              reference.lastKnownBundleURL.isFileURL,
              reference.lastKnownBundleURL.pathExtension.lowercased() == "app" else {
            return false
        }
        if case let .explicit(presetID) = configuration.presetSelection {
            guard let validated = try? ScribePresetID(presetID.rawValue),
                  validated == presetID,
                  presetID.rawValue.hasPrefix("\(configuration.familyID.rawValue).") else { return false }
        }
        if let guidance = configuration.customGuidance {
            guard let validated = try? ScribeCustomGuidance(guidance.rawValue),
                  validated == guidance,
                  !guidance.rawValue.isEmpty else { return false }
        }
        return true
    }

    private static func isUnsupportedControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }
}

private struct ApplicationReferenceKey: Hashable {
    let bundleIdentifier: String
    let bundleURL: URL
}
