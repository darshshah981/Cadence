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

struct AdaptiveScribeV2MigrationResult: Equatable, Sendable {
    let liveReaderState: AdaptiveScribeLiveReaderState
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

    func adaptationEnabled() -> Bool {
        (defaults.object(forKey: Self.adaptationEnabledKey) as? Bool) ?? true
    }

    func restoreAdaptationEnabledForAllApps() {
        defaults.set(true, forKey: Self.adaptationEnabledKey)
    }

    func resetApplicationConfiguration(
        _ id: UUID,
        writer: ApplicationConfigurationWriter
    ) async throws {
        do { try await writer.resetConfiguration(id) }
        catch ApplicationConfigurationWriterError.missingConfiguration { return }
    }

    func resetAllApplicationSettings(writer: ApplicationConfigurationWriter) async throws {
        try await writer.resetAllApplications()
        restoreAdaptationEnabledForAllApps()
    }

    func migrateV2Domains(
        providerConfiguration: ScribeProviderConfigurationLoadResult,
        writingEnvironmentPreferences: WritingEnvironmentPreferenceLoadResult
    ) throws -> AdaptiveScribeV2MigrationResult {
        // Deliberate no-test boundary: migration structurally owns only local defaults and strict stores.
        // Network transport, Keychain cleanup, and application scanning are absent collaborators, so
        // there is no injected side-effect mock to assert against here.
        let markerStore = AdaptiveScribeMigrationMarkerStore(defaults: defaults)
        let providerStore = ScribeProviderLibraryStore(defaults: defaults)
        let applicationStore = ApplicationConfigurationStore(defaults: defaults)
        let presetStore = ScribePresetCatalogStateStore(defaults: defaults)
        let settingsStore = SettingsPresentationStore(defaults: defaults)
        let featureGateStore = AdaptiveScribeFeatureGateStore(defaults: defaults)

        _ = try ProviderLibraryMigrationService(
            destinationStore: providerStore,
            markerStore: markerStore
        ).migrate(providerConfiguration)
        _ = try ApplicationConfigurationMigrationService(
            destinationStore: applicationStore,
            markerStore: markerStore
        ).migrate(writingEnvironmentPreferences)
        try migratePresetCatalogState(store: presetStore, markerStore: markerStore)
        try migrateSettingsPresentation(store: settingsStore, markerStore: markerStore)
        try migrateFeatureGates(store: featureGateStore, markerStore: markerStore)

        return AdaptiveScribeV2MigrationResult(liveReaderState: AdaptiveScribeLiveReaderService(
            providerStore: providerStore,
            applicationStore: applicationStore,
            presetStore: presetStore,
            settingsStore: settingsStore,
            featureGateStore: featureGateStore,
            markerStore: markerStore
        ).load())
    }

    private func migratePresetCatalogState(
        store: ScribePresetCatalogStateStore,
        markerStore: AdaptiveScribeMigrationMarkerStore
    ) throws {
        switch store.load() {
        case .absent:
            try store.save(.generalNeutral)
        case let .valid(state):
            guard state == .generalNeutral else {
                throw AdaptiveScribeMigrationError.destinationConflict
            }
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationConflict
        }
        guard store.load() == .valid(.generalNeutral) else {
            throw AdaptiveScribeMigrationError.semanticReadbackFailed
        }
        switch markerStore.load(.presetCatalogState) {
        case .valid:
            break
        case .absent:
            try markerStore.markComplete(.presetCatalogState)
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        }
    }

    private func migrateSettingsPresentation(
        store: SettingsPresentationStore,
        markerStore: AdaptiveScribeMigrationMarkerStore
    ) throws {
        let initial = SettingsPresentationState(selectedCategory: .general, isAdvancedExpanded: false)
        switch store.load() {
        case .absent:
            try store.save(initial)
        case .valid:
            break
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        }
        guard case .valid = store.load() else {
            throw AdaptiveScribeMigrationError.semanticReadbackFailed
        }
        switch markerStore.load(.settingsPresentation) {
        case .valid:
            break
        case .absent:
            try markerStore.markComplete(.settingsPresentation)
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        }
    }

    private func migrateFeatureGates(
        store: AdaptiveScribeFeatureGateStore,
        markerStore: AdaptiveScribeMigrationMarkerStore
    ) throws {
        switch store.load() {
        case .absent:
            try store.save(.migrationBaseline)
        case .valid:
            break
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        }
        guard case .valid = store.load() else {
            throw AdaptiveScribeMigrationError.semanticReadbackFailed
        }
        switch markerStore.load(.featureGates) {
        case .valid:
            break
        case .absent:
            try markerStore.markComplete(.featureGates)
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        }
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
