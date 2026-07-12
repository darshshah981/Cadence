import Foundation
import Testing
@testable import Cadence

struct WritingEnvironmentTests {
    @Test
    func bundledCatalogHasStableFirstSliceDefinitions() throws {
        let catalog = WritingEnvironmentCatalog.releaseOne

        let slack = try #require(catalog.environment(id: .slack))
        #expect(slack.defaultBehaviorID == .neutral)
        #expect(slack.supportedBehaviorIDs == [.formal, .neutral, .casual])

        let claudeCode = try #require(catalog.environment(id: .claudeCode))
        #expect(claudeCode.defaultBehaviorID == .precise)
        #expect(claudeCode.supportedBehaviorIDs == [.precise])

        let global = try #require(catalog.environment(id: .global))
        #expect(global.displayName == "Other apps")
        #expect(global.defaultBehaviorID == .neutral)
    }

    @Test
    func resolverUsesDefaultsRememberedBehaviorAndDisabledFallback() {
        let catalog = WritingEnvironmentCatalog.releaseOne

        #expect(WritingEnvironmentResolver.resolve(
            recognizedEnvironmentID: .slack,
            adaptationEnabled: true,
            preferenceLoadResult: .absent,
            catalog: catalog
        ).cue == "Slack · Neutral")

        let casual = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .casual,
            definitionVersion: 1
        )
        #expect(WritingEnvironmentResolver.resolve(
            recognizedEnvironmentID: .slack,
            adaptationEnabled: true,
            preferenceLoadResult: .valid([casual]),
            catalog: catalog
        ).cue == "Slack · Casual")

        let disabled = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: false,
            selectedBehaviorID: .casual,
            definitionVersion: 1
        )
        let fallback = WritingEnvironmentResolver.resolve(
            recognizedEnvironmentID: .slack,
            adaptationEnabled: true,
            preferenceLoadResult: .valid([disabled]),
            catalog: catalog
        )
        #expect(fallback.environmentID == .global)
        #expect(fallback.behaviorID == .neutral)
        #expect(fallback.cue == "Other apps · Neutral")
    }

    @Test
    func invalidPreferenceStateFailsClosedToOtherAppsNeutral() {
        let catalog = WritingEnvironmentCatalog.releaseOne
        let casual = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .casual,
            definitionVersion: 1
        )

        for result in [
            WritingEnvironmentPreferenceLoadResult.rejected(.malformed),
            .valid([casual, casual]),
            .valid([WritingEnvironmentPreference(
                environmentID: .slack,
                isEnabled: true,
                selectedBehaviorID: .precise,
                definitionVersion: 1
            )])
        ] {
            let resolved = WritingEnvironmentResolver.resolve(
                recognizedEnvironmentID: .slack,
                adaptationEnabled: true,
                preferenceLoadResult: result,
                catalog: catalog
            )
            #expect(resolved.environmentID == .global)
            #expect(resolved.behaviorID == .neutral)
            #expect(resolved.resolutionSource == .invalidPreferenceFallback)
        }
    }

    @Test
    func storeDistinguishesAbsenceValidAndRejectedData() throws {
        let suite = "CadenceTests.WritingEnvironment.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WritingEnvironmentStore(defaults: defaults, key: "environments")

        #expect(store.load() == .absent)

        let preference = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .formal,
            definitionVersion: 1
        )
        try store.save([preference])
        #expect(store.load() == .valid([preference]))

        defaults.set(Data("not-json".utf8), forKey: "environments")
        #expect(store.load() == .rejected(.malformed))

        let future = WritingEnvironmentPreferenceLibrary(
            schemaVersion: 999,
            preferences: []
        )
        defaults.set(try JSONEncoder().encode(future), forKey: "environments")
        #expect(store.load() == .rejected(.futureSchema))
    }

    @Test
    func migrationIsAdditiveIdempotentAndLeavesLegacyDomainsByteForByte() throws {
        let suite = "CadenceTests.AdaptiveMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let personalizationStore = PersonalizationStore(defaults: defaults)
        try personalizationStore.save(PersonalizationLibrary(
            shortcuts: [PersonalShortcut(trigger: "ship it", template: "Please ship it")],
            styleProfiles: [WritingStyleProfile(name: "Legacy Slack")]
        ))
        defaults.set("HOTKEY_CANARY", forKey: "Cadence.scribeKeyDisplay")
        defaults.set(Data("MEETING_CANARY".utf8), forKey: "Cadence.meetingCanary")
        let legacyBytes = try #require(defaults.data(forKey: "Cadence.personalizationLibrary"))
        let migration = AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: personalizationStore,
            now: { Date(timeIntervalSince1970: 123) }
        )

        let first = try migration.migrate(
            scribeEnabled: true,
            legacyLocalAvailable: true,
            providerConfiguration: .absent
        )
        let second = try migration.migrate(
            scribeEnabled: true,
            legacyLocalAvailable: true,
            providerConfiguration: .absent
        )

        #expect(first == second)
        #expect(first.outcome == .legacyLocalRetained)
        #expect(first.shouldShowLegacyProfileNotice)
        #expect(defaults.bool(forKey: AdaptiveScribeMigrationService.adaptationEnabledKey))
        #expect(WritingEnvironmentStore(defaults: defaults).load() == .absent)
        #expect(defaults.data(forKey: "Cadence.personalizationLibrary") == legacyBytes)
        #expect(defaults.string(forKey: "Cadence.scribeKeyDisplay") == "HOTKEY_CANARY")
        #expect(defaults.data(forKey: "Cadence.meetingCanary") == Data("MEETING_CANARY".utf8))
        #expect(defaults.data(forKey: AdaptiveScribeMigrationService.ledgerKey) != nil)
    }

    @Test
    func adaptationCompatibilityPreservesFalseAndWrongTypeAndResetAllRestoresOnlyEnabled() throws {
        let suite = "CadenceTests.AdaptationCompatibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: PersonalizationStore(defaults: defaults)
        )

        #expect(service.adaptationEnabled())
        defaults.set(false, forKey: AdaptiveScribeMigrationService.adaptationEnabledKey)
        #expect(!service.adaptationEnabled())
        defaults.set("legacy-wrong-type", forKey: AdaptiveScribeMigrationService.adaptationEnabledKey)
        #expect(service.adaptationEnabled())
        #expect(defaults.string(forKey: AdaptiveScribeMigrationService.adaptationEnabledKey) == "legacy-wrong-type")
        defaults.set(Data("provider-canary".utf8), forKey: CadenceDurablePreferenceKeys.providerLibrary)

        service.restoreAdaptationEnabledForAllApps()

        #expect(service.adaptationEnabled())
        #expect(defaults.data(forKey: CadenceDurablePreferenceKeys.providerLibrary) == Data("provider-canary".utf8))
    }

    @Test
    func v2MigrationCreatesIndependentMarkersAndLeavesLegacyStoresReadable() throws {
        let suite = "CadenceTests.V2Migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let personalization = PersonalizationStore(defaults: defaults)
        let service = AdaptiveScribeMigrationService(defaults: defaults, personalizationStore: personalization)
        let provider = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "retained-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let environments = [WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .formal,
            definitionVersion: 1
        )]
        let providerStore = ScribeProviderConfigurationStore(defaults: defaults)
        let environmentStore = WritingEnvironmentStore(defaults: defaults)
        try providerStore.save(provider)
        try environmentStore.save(environments)
        let providerBytes = try #require(defaults.data(forKey: ScribeProviderConfigurationStore.defaultKey))
        let environmentBytes = try #require(defaults.data(forKey: WritingEnvironmentStore.defaultKey))

        let result = try service.migrateV2Domains(
            providerConfiguration: providerStore.load(),
            writingEnvironmentPreferences: environmentStore.load()
        )

        #expect(result.liveReaderState.scribeAvailability == .setupRequired)
        let markers = AdaptiveScribeMigrationMarkerStore(defaults: defaults)
        #expect(AdaptiveScribeMigrationDomain.allCases.allSatisfy { markers.load($0) == .valid })
        #expect(defaults.data(forKey: ScribeProviderConfigurationStore.defaultKey) == providerBytes)
        #expect(defaults.data(forKey: WritingEnvironmentStore.defaultKey) == environmentBytes)
        #expect(providerStore.load() == .valid(provider))
        #expect(environmentStore.load() == .valid(environments))
    }

    @Test
    @MainActor
    func appModelExactAndAllAppResetsPreserveLegacyAndOtherDurableDomains() async throws {
        let suite = "CadenceTests.V2AppReset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appStore = ApplicationConfigurationStore(defaults: defaults)
        let first = try migratedAppConfiguration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            referenceID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            bundleID: "com.tinyspeck.slackmacgap",
            path: "/Applications/Slack.app"
        )
        let second = try migratedAppConfiguration(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            referenceID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            bundleID: "com.todesktop.230313mzl4w4u92",
            path: "/Applications/Cursor.app"
        )
        try appStore.save(.init(revision: 1, configurations: [first, second]))
        let legacyStore = WritingEnvironmentStore(defaults: defaults)
        let legacyPreferences = [WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .casual,
            definitionVersion: 1
        )]
        try legacyStore.save(legacyPreferences)
        let legacyBytes = try #require(defaults.data(forKey: WritingEnvironmentStore.defaultKey))
        defaults.set(false, forKey: AdaptiveScribeMigrationService.adaptationEnabledKey)
        let providerCanary = Data("provider".utf8)
        let presetCanary = Data("preset".utf8)
        defaults.set(providerCanary, forKey: CadenceDurablePreferenceKeys.providerLibrary)
        defaults.set(presetCanary, forKey: CadenceDurablePreferenceKeys.presetCatalogState)
        let service = AdaptiveScribeMigrationService(
            defaults: defaults,
            personalizationStore: PersonalizationStore(defaults: defaults)
        )

        try await service.resetApplicationConfiguration(
            first.id,
            writer: ApplicationConfigurationWriter(store: appStore)
        )
        guard case let .valid(afterExact) = appStore.load() else {
            Issue.record("Expected app library")
            return
        }
        #expect(afterExact.configurations.map(\.id) == [second.id])
        #expect(!service.adaptationEnabled())

        try await AppModel.performResetAllApplicationSettings(
            defaults: defaults,
            writer: ApplicationConfigurationWriter(store: appStore),
            personalizationStore: PersonalizationStore(defaults: defaults)
        )
        guard case let .valid(afterAll) = appStore.load() else {
            Issue.record("Expected reset app library")
            return
        }
        #expect(afterAll.configurations.isEmpty)
        #expect(service.adaptationEnabled())
        #expect(defaults.data(forKey: CadenceDurablePreferenceKeys.providerLibrary) == providerCanary)
        #expect(defaults.data(forKey: CadenceDurablePreferenceKeys.presetCatalogState) == presetCanary)
        #expect(defaults.data(forKey: WritingEnvironmentStore.defaultKey) == legacyBytes)
        #expect(legacyStore.load() == .valid(legacyPreferences))
    }

    private func migratedAppConfiguration(
        id: UUID,
        referenceID: UUID,
        bundleID: String,
        path: String
    ) throws -> ApplicationConfiguration {
        try ApplicationConfiguration(
            id: id,
            application: ApplicationReference(
                id: referenceID,
                bundleIdentifier: bundleID,
                lastKnownBundleURL: URL(fileURLWithPath: path),
                lastKnownDisplayName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            ),
            isEnabled: true,
            familyID: bundleID.contains("slack") ? .messaging : .coding,
            presetSelection: .familyDefault,
            customGuidance: try ScribeCustomGuidance("Custom guidance"),
            revision: 1
        )
    }
}
