import Foundation

struct WritingEnvironmentStore {
    static let defaultKey = "Cadence.writingEnvironmentPreferences"

    private let defaults: UserDefaults
    private let key: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        key: String = WritingEnvironmentStore.defaultKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
        self.decoder = decoder
    }

    func load() -> WritingEnvironmentPreferenceLoadResult {
        guard let data = defaults.data(forKey: key) else {
            return .absent
        }
        guard let library = try? decoder.decode(WritingEnvironmentPreferenceLibrary.self, from: data) else {
            return .rejected(.malformed)
        }
        guard library.schemaVersion <= WritingEnvironmentPreferenceLibrary.currentSchemaVersion else {
            return .rejected(.futureSchema)
        }
        guard library.schemaVersion == WritingEnvironmentPreferenceLibrary.currentSchemaVersion else {
            return .rejected(.malformed)
        }
        return .valid(library.preferences)
    }

    func save(_ preferences: [WritingEnvironmentPreference]) throws {
        let library = WritingEnvironmentPreferenceLibrary(preferences: preferences)
        defaults.set(try encoder.encode(library), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
