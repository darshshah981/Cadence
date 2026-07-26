import Foundation
import OSLog

private let personalizationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Personalization"
)

final class PersonalizationStore {
    private static let spokenShortcutsEnabledKey = "Cadence.spokenShortcutsEnabled"
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "Cadence.personalizationLibrary") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> PersonalizationLibrary {
        guard let data = defaults.data(forKey: key) else { return .empty }
        guard let library = try? JSONDecoder().decode(PersonalizationLibrary.self, from: data),
              library.schemaVersion == PersonalizationLibrary.currentSchemaVersion else {
            personalizationLogger.error("Personalization library could not be loaded")
            return .empty
        }
        return library
    }

    func save(_ library: PersonalizationLibrary) throws {
        let normalized = PersonalizationLibrary(
            shortcuts: library.shortcuts,
            styleProfiles: library.styleProfiles
        )
        defaults.set(try JSONEncoder().encode(normalized), forKey: key)
    }

    func areSpokenShortcutsEnabled() -> Bool {
        (defaults.object(forKey: Self.spokenShortcutsEnabledKey) as? Bool) ?? true
    }

    func setSpokenShortcutsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.spokenShortcutsEnabledKey)
    }
}
