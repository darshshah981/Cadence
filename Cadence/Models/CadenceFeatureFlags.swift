import Foundation

struct CadenceFeatureFlags: Equatable, Sendable {
    static let scribeDefaultsKey = "Cadence.feature.scribe"
    static let scribeEnvironmentKey = "CADENCE_SCRIBE_ENABLED"
    static let granolaDefaultsKey = "Cadence.feature.granola"
    static let granolaEnvironmentKey = "CADENCE_GRANOLA_ENABLED"

    let scribeEnabled: Bool
    let granolaEnabled: Bool

    static func resolve(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> CadenceFeatureFlags {
        CadenceFeatureFlags(
            scribeEnabled: resolveFeature(
                defaults: defaults,
                environment: environment,
                arguments: arguments,
                defaultsKey: scribeDefaultsKey,
                environmentKey: scribeEnvironmentKey,
                enableArguments: ["--enable-scribe", "--scribe-fixture"],
                disableArgument: "--disable-scribe",
                defaultValue: true
            ),
            granolaEnabled: resolveFeature(
                defaults: defaults,
                environment: environment,
                arguments: arguments,
                defaultsKey: granolaDefaultsKey,
                environmentKey: granolaEnvironmentKey,
                enableArguments: ["--enable-granola"],
                disableArgument: "--disable-granola",
                defaultValue: false
            )
        )
    }

    private static func resolveFeature(
        defaults: UserDefaults,
        environment: [String: String],
        arguments: [String],
        defaultsKey: String,
        environmentKey: String,
        enableArguments: Set<String>,
        disableArgument: String,
        defaultValue: Bool
    ) -> Bool {
        if arguments.contains(disableArgument) {
            return false
        }
        if !enableArguments.isDisjoint(with: arguments) {
            return true
        }
        if let environmentValue = environment[environmentKey],
           let enabled = parseBoolean(environmentValue) {
            return enabled
        }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return defaultValue
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
