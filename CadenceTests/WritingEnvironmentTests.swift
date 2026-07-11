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
}
