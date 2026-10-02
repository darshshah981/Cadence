import Foundation
import OSLog

private let composeGlobalDefaultsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Cadence", category: "ComposeGlobalDefaults")

enum ComposeGlobalWritingDefaultsError: Error, Equatable { case invalidStoredDefaults, staleEdit }

/// A caller owns the UserDefaults key. Reads never repair or overwrite corrupt
/// or newer records. Save is explicit and checks the editor's loaded value.
struct ComposeGlobalWritingDefaultsStore {
    private struct Envelope: Codable { let schemaVersion: Int; let choices: ComposeGlobalWritingDefaults }
    let defaults: UserDefaults
    let key: String

    func load() throws -> ComposeGlobalWritingDefaults {
        guard let object = defaults.object(forKey: key) else { return .init() }
        guard let data = object as? Data, data.count <= 4096,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1 else { throw ComposeGlobalWritingDefaultsError.invalidStoredDefaults }
        return envelope.choices
    }

    func save(_ choices: ComposeGlobalWritingDefaults, replacing expected: ComposeGlobalWritingDefaults) throws {
        guard try load() == expected else { throw ComposeGlobalWritingDefaultsError.staleEdit }
        defaults.set(try JSONEncoder().encode(Envelope(schemaVersion: 1, choices: choices)), forKey: key)
    }

    func reset(replacing expected: ComposeGlobalWritingDefaults) throws {
        guard try load() == expected else { throw ComposeGlobalWritingDefaultsError.staleEdit }
        defaults.removeObject(forKey: key)
    }

    /// Only an explicit recovery action may remove an unreadable payload.
    /// If another editor repaired it meanwhile, preserve that valid value.
    func removeUnreadableDefaults() throws {
        do { _ = try load() }
        catch ComposeGlobalWritingDefaultsError.invalidStoredDefaults {
            defaults.removeObject(forKey: key)
            return
        }
        throw ComposeGlobalWritingDefaultsError.staleEdit
    }
}
