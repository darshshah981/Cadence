import Foundation

enum AdaptiveScribeMigrationOutcome: String, Codable, Equatable, Sendable {
    case disabledRetained
    case legacyLocalRetained
    case setupRequired
    case cloudConfigurationRetained
    case failed
}

struct AdaptiveScribeMigrationLedger: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentMigrationVersion = 1

    let schemaVersion: Int
    let migrationVersion: Int
    let outcome: AdaptiveScribeMigrationOutcome
    let completedAt: Date

    init(
        schemaVersion: Int = AdaptiveScribeMigrationLedger.currentSchemaVersion,
        migrationVersion: Int = AdaptiveScribeMigrationLedger.currentMigrationVersion,
        outcome: AdaptiveScribeMigrationOutcome,
        completedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.migrationVersion = migrationVersion
        self.outcome = outcome
        self.completedAt = completedAt
    }
}

struct AdaptiveScribeMigrationResult: Equatable, Sendable {
    let outcome: AdaptiveScribeMigrationOutcome
    let shouldShowLegacyProfileNotice: Bool
}

struct AdaptiveScribeMigrationService {
    static let ledgerKey = "Cadence.adaptiveScribeMigrationLedger"
    static let adaptationEnabledKey = "Cadence.adaptScribeToApp"
    static let legacyNoticeKey = "Cadence.adaptiveScribeLegacyProfileNotice"

    private let defaults: UserDefaults
    private let personalizationStore: PersonalizationStore
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        personalizationStore: PersonalizationStore = PersonalizationStore(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.personalizationStore = personalizationStore
        self.now = now
    }

    func migrate(
        scribeEnabled: Bool,
        legacyLocalAvailable: Bool,
        providerConfiguration: ScribeProviderConfigurationLoadResult
    ) throws -> AdaptiveScribeMigrationResult {
        if let existing = loadCurrentLedger() {
            return AdaptiveScribeMigrationResult(
                outcome: existing.outcome,
                shouldShowLegacyProfileNotice: defaults.bool(forKey: Self.legacyNoticeKey)
            )
        }

        let outcome: AdaptiveScribeMigrationOutcome
        let providerReady: Bool
        switch providerConfiguration {
        case let .valid(configuration):
            outcome = .cloudConfigurationRetained
            providerReady = configuration.isEnabled
        case .rejected:
            outcome = .failed
            providerReady = false
        case .absent:
            if !scribeEnabled {
                outcome = .disabledRetained
                providerReady = false
            } else if legacyLocalAvailable {
                outcome = .legacyLocalRetained
                providerReady = true
            } else {
                outcome = .setupRequired
                providerReady = false
            }
        }

        if providerReady, defaults.object(forKey: Self.adaptationEnabledKey) == nil {
            defaults.set(true, forKey: Self.adaptationEnabledKey)
        }
        if !personalizationStore.load().styleProfiles.isEmpty,
           defaults.object(forKey: Self.legacyNoticeKey) == nil {
            defaults.set(true, forKey: Self.legacyNoticeKey)
        }

        let ledger = AdaptiveScribeMigrationLedger(
            outcome: outcome,
            completedAt: now()
        )
        defaults.set(try JSONEncoder().encode(ledger), forKey: Self.ledgerKey)
        return AdaptiveScribeMigrationResult(
            outcome: outcome,
            shouldShowLegacyProfileNotice: defaults.bool(forKey: Self.legacyNoticeKey)
        )
    }

    func dismissLegacyProfileNotice() {
        defaults.set(false, forKey: Self.legacyNoticeKey)
    }

    private func loadCurrentLedger() -> AdaptiveScribeMigrationLedger? {
        guard let data = defaults.data(forKey: Self.ledgerKey),
              let ledger = try? JSONDecoder().decode(AdaptiveScribeMigrationLedger.self, from: data),
              ledger.schemaVersion == AdaptiveScribeMigrationLedger.currentSchemaVersion,
              ledger.migrationVersion == AdaptiveScribeMigrationLedger.currentMigrationVersion else {
            return nil
        }
        return ledger
    }
}
