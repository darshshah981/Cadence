import Foundation

final class SettingsPresentationStore {
    static let defaultKey = CadenceDurablePreferenceKeys.settingsPresentation

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SettingsPresentationStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SettingsPresentationLoadResult {
        guard let data = defaults.data(forKey: key) else { return .absent }
        guard let envelope = try? JSONDecoder().decode(SettingsPresentationEnvelope.self, from: data) else {
            return .rejected(.malformed)
        }
        guard envelope.schemaVersion <= SettingsPresentationEnvelope.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard envelope.schemaVersion == SettingsPresentationEnvelope.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        return .valid(envelope.state)
    }

    func loadNormalizingCategories(
        scribeEnabled: Bool,
        granolaEnabled: Bool
    ) -> SettingsPresentationLoadResult {
        let result = load()
        guard case let .valid(state) = result else {
            return result
        }
        let normalizedState = SettingsPresentationState(
            selectedCategory: state.selectedCategory.normalized(
                scribeEnabled: scribeEnabled,
                granolaEnabled: granolaEnabled
            ),
            isAdvancedExpanded: state.isAdvancedExpanded
        )
        if normalizedState != state {
            try? save(normalizedState)
        }
        return .valid(normalizedState)
    }

    func save(_ state: SettingsPresentationState) throws {
        let previous = defaults.data(forKey: key)
        defaults.set(try JSONEncoder().encode(SettingsPresentationEnvelope(state: state)), forKey: key)
        guard load() == .valid(state) else {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            throw StrictPersistenceError.semanticReadbackFailed
        }
    }

    /// Presentation state is disposable UI state. Removing a rejected value is
    /// intentionally separate from feature availability so a future settings
    /// category cannot strand the whole router.
    func clear() {
        defaults.removeObject(forKey: key)
    }
}
