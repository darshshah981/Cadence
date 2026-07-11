#if DEBUG
import Foundation

enum ScribeLaunchFixture: String {
    case setup
    case settings
    case slackReview
    case insertionRecovery
}

enum ScribeLaunchFixtures {
    static var current: ScribeLaunchFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--scribe-fixture"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return ScribeLaunchFixture(rawValue: arguments[index + 1])
    }

    static var disablesLegacyProvider: Bool {
        current == .setup
    }

    static var usesIsolatedRuntimeStorage: Bool {
        current != nil || NSClassFromString("XCTestCase") != nil
    }

    static func runtimeDefaults() -> UserDefaults {
        guard usesIsolatedRuntimeStorage else { return .standard }
        let suffix = current?.rawValue ?? "unit-test-host"
        let suiteName = "com.darshshah.Cadence.debug.\(suffix)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Cadence could not create isolated debug defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    static func credentialStore() -> any ScribeCredentialStoring {
        usesIsolatedRuntimeStorage
            ? VolatileScribeCredentialStore()
            : KeychainScribeCredentialStore()
    }

    static var panelWidth: CGFloat? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--scribe-fixture-width"),
              arguments.indices.contains(index + 1),
              let width = Double(arguments[index + 1]),
              (520...720).contains(width) else {
            return nil
        }
        return CGFloat(width)
    }

    static func apply(to defaults: UserDefaults) {
        guard current != nil else { return }
        defaults.removeObject(forKey: ScribeProviderConfigurationStore.defaultKey)
        defaults.removeObject(forKey: WritingEnvironmentStore.defaultKey)
        defaults.removeObject(forKey: AdaptiveScribeMigrationService.ledgerKey)
        try? OnboardingProgressStore(defaults: defaults).save(OnboardingProgress(
            stepIndex: OnboardingStep.allCases.count - 1,
            isComplete: true,
            wasSkipped: false
        ))
        defaults.set(true, forKey: "Cadence.scribeEnabled")
        defaults.set(true, forKey: AdaptiveScribeMigrationService.adaptationEnabledKey)
    }
}

private final class VolatileScribeCredentialStore: ScribeCredentialStoring {
    private var values: [ScribeCredentialReference: String] = [:]

    func stage(_ credential: String) throws -> ScribeCredentialReference {
        guard !credential.isEmpty,
              !credential.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ScribeCredentialStoreError.invalidCredential
        }
        let reference = ScribeCredentialReference(rawValue: UUID().uuidString)
        values[reference] = credential
        return reference
    }

    func load(reference: ScribeCredentialReference) throws -> String? {
        values[reference]
    }

    func delete(reference: ScribeCredentialReference) throws {
        values.removeValue(forKey: reference)
    }

    func allReferences() throws -> Set<ScribeCredentialReference> {
        Set(values.keys)
    }
}
#endif
