import Foundation

struct CadenceFeatureFlags: Equatable, Sendable {
    static let scribeDefaultsKey = "Cadence.feature.scribe"
    static let scribeEnvironmentKey = "CADENCE_SCRIBE_ENABLED"
    static let granolaDefaultsKey = "Cadence.feature.granola"
    static let granolaEnvironmentKey = "CADENCE_GRANOLA_ENABLED"
    static let composeContextDefaultsKey = "Cadence.feature.composeContext"
    static let composeContextEnvironmentKey = "CADENCE_COMPOSE_CONTEXT_ENABLED"
    static let composeMemoryDefaultsKey = "Cadence.feature.composeMemory"
    static let composeMemoryEnvironmentKey = "CADENCE_COMPOSE_MEMORY_ENABLED"
    static let composePersistentMemoryDefaultsKey = "Cadence.feature.composePersistentMemory"
    static let composePersistentMemoryEnvironmentKey = "CADENCE_COMPOSE_PERSISTENT_MEMORY_ENABLED"
    static let composeAdaptersDefaultsKey = "Cadence.feature.composeAdapters"
    static let composeAdaptersEnvironmentKey = "CADENCE_COMPOSE_ADAPTERS_ENABLED"

    let scribeEnabled: Bool
    let granolaEnabled: Bool
    let composeContextEnabled: Bool
    let composeMemoryEnabled: Bool
    let composePersistentMemoryEnabled: Bool
    let composeAdaptersEnabled: Bool

    func effectiveSelectedTextPreferences(
        _ stored: ComposeSelectedTextContextPreferences
    ) -> ComposeSelectedTextContextPreferences {
        composeContextEnabled ? stored : .init()
    }

    static func resolve(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> CadenceFeatureFlags {
        let scribe = resolveFeature(
            defaults: defaults,
            environment: environment,
            arguments: arguments,
            defaultsKey: scribeDefaultsKey,
            environmentKey: scribeEnvironmentKey,
            enableArguments: ["--enable-scribe", "--scribe-fixture"],
            disableArgument: "--disable-scribe",
            defaultValue: true
        )
        let context = scribe && resolveFeature(
            defaults: defaults, environment: environment, arguments: arguments,
            defaultsKey: composeContextDefaultsKey, environmentKey: composeContextEnvironmentKey,
            enableArguments: ["--enable-compose-context"], disableArgument: "--disable-compose-context",
            defaultValue: true
        )
        let memory = context && resolveFeature(
            defaults: defaults, environment: environment, arguments: arguments,
            defaultsKey: composeMemoryDefaultsKey, environmentKey: composeMemoryEnvironmentKey,
            enableArguments: ["--enable-compose-memory"], disableArgument: "--disable-compose-memory",
            defaultValue: false
        )
        let adapters = context && resolveFeature(
            defaults: defaults, environment: environment, arguments: arguments,
            defaultsKey: composeAdaptersDefaultsKey, environmentKey: composeAdaptersEnvironmentKey,
            enableArguments: ["--enable-compose-adapters"], disableArgument: "--disable-compose-adapters",
            defaultValue: false
        )
        return CadenceFeatureFlags(
            scribeEnabled: scribe,
            granolaEnabled: resolveFeature(
                defaults: defaults,
                environment: environment,
                arguments: arguments,
                defaultsKey: granolaDefaultsKey,
                environmentKey: granolaEnvironmentKey,
                enableArguments: ["--enable-granola"],
                disableArgument: "--disable-granola",
                defaultValue: false
            ),
            composeContextEnabled: context,
            composeMemoryEnabled: memory,
            composePersistentMemoryEnabled: memory && adapters && resolveFeature(
                defaults: defaults, environment: environment, arguments: arguments,
                defaultsKey: composePersistentMemoryDefaultsKey,
                environmentKey: composePersistentMemoryEnvironmentKey,
                enableArguments: ["--enable-compose-persistent-memory"],
                disableArgument: "--disable-compose-persistent-memory",
                defaultValue: false
            ),
            composeAdaptersEnabled: adapters
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
