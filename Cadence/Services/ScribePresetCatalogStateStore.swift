import Foundation

final class ScribePresetCatalogStateStore {
    static let defaultKey = CadenceDurablePreferenceKeys.presetCatalogState
    static let supportedCatalogRevisions: Set<Int> = [1]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = ScribePresetCatalogStateStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> ScribePresetCatalogStateLoadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let envelope = try? JSONDecoder().decode(ScribePresetCatalogStateEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard envelope.schemaVersion <= ScribePresetCatalogStateEnvelope.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard envelope.schemaVersion == ScribePresetCatalogStateEnvelope.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        guard Self.supportedCatalogRevisions.contains(envelope.state.catalogRevision) else {
            return .rejected(.unsupportedCatalogRevision)
        }
        guard envelope.state.fallbackFamilyID == .general,
              envelope.state.fallbackPresetID == ScribePresetCatalogState.generalNeutral.fallbackPresetID else {
            return .rejected(.invalidState)
        }
        return .valid(envelope.state)
    }

    func save(_ state: ScribePresetCatalogState) throws {
        guard Self.supportedCatalogRevisions.contains(state.catalogRevision),
              state.fallbackFamilyID == .general,
              state.fallbackPresetID == ScribePresetCatalogState.generalNeutral.fallbackPresetID else {
            throw StrictPersistenceError.invalidValue
        }
        let previous = defaults.data(forKey: key)
        defaults.set(try JSONEncoder().encode(ScribePresetCatalogStateEnvelope(state: state)), forKey: key)
        guard load() == .valid(state) else {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            throw StrictPersistenceError.semanticReadbackFailed
        }
    }
}
