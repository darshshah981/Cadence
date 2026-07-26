import Foundation

struct CadenceFeatureFlags: Equatable, Sendable {
    static let scribeDefaultsKey = "Cadence.feature.scribe"
    static let scribeEnvironmentKey = "CADENCE_SCRIBE_ENABLED"

    let scribeEnabled: Bool

    static func resolve(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> CadenceFeatureFlags {
        if arguments.contains("--disable-scribe") {
            return CadenceFeatureFlags(scribeEnabled: false)
        }
        if arguments.contains("--enable-scribe")
            || arguments.contains("--scribe-fixture") {
            return CadenceFeatureFlags(scribeEnabled: true)
        }
        if let environmentValue = environment[scribeEnvironmentKey],
           let enabled = parseBoolean(environmentValue) {
            return CadenceFeatureFlags(scribeEnabled: enabled)
        }
        if defaults.object(forKey: scribeDefaultsKey) != nil {
            return CadenceFeatureFlags(
                scribeEnabled: defaults.bool(forKey: scribeDefaultsKey)
            )
        }
        return CadenceFeatureFlags(scribeEnabled: true)
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
