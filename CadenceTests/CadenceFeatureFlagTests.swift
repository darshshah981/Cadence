import Foundation
import Testing
@testable import Cadence

struct CadenceFeatureFlagTests {
    @Test
    func coreComposeIsAvailableAndExperimentalContextIsOffByDefault() throws {
        let suite = "CadenceFeatureFlagTests.default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let flags = CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: [:],
            arguments: []
        )

        #expect(flags.scribeEnabled)
        #expect(flags.granolaEnabled == false)
        #expect(!flags.composeContextEnabled)
        #expect(!flags.composeMemoryEnabled)
        #expect(!flags.composePersistentMemoryEnabled)
        #expect(!flags.composeAdaptersEnabled)
        let consent = ComposeSessionMemoryPreferences()
        #expect(!consent.permitsTextEditUse)
        #expect(!consent.permitsTextEditRetention)
        #expect(!consent.permitsLocalDraftUse)
    }

    @Test
    func contextKillSwitchPreservesStoredConsentButDisablesRuntimeCapture() throws {
        let suite = "CadenceFeatureFlagTests.context.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CadenceFeatureFlags.composeContextDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.composeMemoryDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.composePersistentMemoryDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.composeAdaptersDefaultsKey)
        let stored = ComposeSelectedTextContextPreferences(
            isEnabled: true, textEditAllowed: true,
            disclosureRevision: ComposeSelectedTextContextPreferences.currentDisclosureRevision
        )
        let flags = CadenceFeatureFlags.resolve(defaults: defaults, environment: [:], arguments: [])
        #expect(flags.scribeEnabled)
        #expect(!flags.composeContextEnabled)
        #expect(!flags.composeMemoryEnabled)
        #expect(!flags.composePersistentMemoryEnabled)
        #expect(!flags.composeAdaptersEnabled)
        #expect(!flags.effectiveSelectedTextPreferences(stored).permitsTextEditCapture)
        #expect(stored.permitsTextEditCapture)
        #expect(CadenceFeatureFlags.resolve(
            defaults: defaults, environment: [:], arguments: ["--enable-compose-context"]
        ).effectiveSelectedTextPreferences(stored) == stored)
    }

    @Test
    func memoryAndAdaptersRequireContextAndMasterCompose() throws {
        let suite = "CadenceFeatureFlagTests.hierarchy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let env = [
            CadenceFeatureFlags.composeContextEnvironmentKey: "true",
            CadenceFeatureFlags.composeMemoryEnvironmentKey: "true",
            CadenceFeatureFlags.composePersistentMemoryEnvironmentKey: "true",
            CadenceFeatureFlags.composeAdaptersEnvironmentKey: "true"
        ]
        let enabled = CadenceFeatureFlags.resolve(defaults: defaults, environment: env, arguments: [])
        #expect(enabled.composeContextEnabled && enabled.composeMemoryEnabled && enabled.composeAdaptersEnabled)
        #expect(enabled.composePersistentMemoryEnabled)
        let contextOff = CadenceFeatureFlags.resolve(
            defaults: defaults, environment: env, arguments: ["--disable-compose-context"]
        )
        #expect(!contextOff.composeContextEnabled && !contextOff.composeMemoryEnabled && !contextOff.composeAdaptersEnabled)
        #expect(!contextOff.composePersistentMemoryEnabled)
        let masterOff = CadenceFeatureFlags.resolve(
            defaults: defaults, environment: env, arguments: ["--disable-scribe"]
        )
        #expect(!masterOff.scribeEnabled && !masterOff.composeContextEnabled
                && !masterOff.composeMemoryEnabled && !masterOff.composeAdaptersEnabled)
        #expect(!masterOff.composePersistentMemoryEnabled)
        let memoryOff = CadenceFeatureFlags.resolve(
            defaults: defaults, environment: env, arguments: ["--disable-compose-memory"]
        )
        #expect(memoryOff.composeContextEnabled && !memoryOff.composeMemoryEnabled && memoryOff.composeAdaptersEnabled)
        #expect(!memoryOff.composePersistentMemoryEnabled)
        let adaptersOff = CadenceFeatureFlags.resolve(
            defaults: defaults, environment: env, arguments: ["--disable-compose-adapters"]
        )
        #expect(adaptersOff.composeMemoryEnabled && !adaptersOff.composeAdaptersEnabled)
        #expect(!adaptersOff.composePersistentMemoryEnabled)
        let durableOff = CadenceFeatureFlags.resolve(
            defaults: defaults, environment: env, arguments: ["--disable-compose-persistent-memory"]
        )
        #expect(durableOff.composeMemoryEnabled && durableOff.composeAdaptersEnabled)
        #expect(!durableOff.composePersistentMemoryEnabled)
    }

    @Test
    func productFeaturesCanBeEnabledWithDurableFeatureFlags() throws {
        let suite = "CadenceFeatureFlagTests.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CadenceFeatureFlags.scribeDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.granolaDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.composeContextDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.composeMemoryDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.composeAdaptersDefaultsKey)

        let flags = CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: [:],
            arguments: []
        )

        #expect(flags.scribeEnabled)
        #expect(flags.granolaEnabled)
        #expect(flags.composeContextEnabled)
        #expect(flags.composeMemoryEnabled)
        #expect(flags.composeAdaptersEnabled)
        #expect(!flags.composePersistentMemoryEnabled)
    }

    @Test
    func launchOverridesSupportTemporaryEnableAndDisable() throws {
        let suite = "CadenceFeatureFlagTests.launch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CadenceFeatureFlags.scribeDefaultsKey)

        #expect(CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: [:],
            arguments: ["--disable-scribe"]
        ).scribeEnabled == false)
        #expect(CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: ["CADENCE_SCRIBE_ENABLED": "1"],
            arguments: ["--enable-scribe"]
        ).scribeEnabled)
        #expect(CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: ["CADENCE_GRANOLA_ENABLED": "1"],
            arguments: ["--disable-granola"]
        ).granolaEnabled == false)
        #expect(CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: ["CADENCE_GRANOLA_ENABLED": "1"],
            arguments: []
        ).granolaEnabled)
    }

    @Test
    func settingsCategoriesHideDisabledFeaturesAndNormalizeLegacySelections() {
        #expect(SettingsCategoryID.visibleCategories(
            scribeEnabled: false,
            granolaEnabled: false
        ) == [
            .general, .dictation, .privacy, .advanced
        ])
        #expect(SettingsCategoryID.visibleCategories(
            scribeEnabled: true,
            granolaEnabled: true
        ) == [
            .general, .dictation, .scribe, .meetings, .privacy, .advanced
        ])
        #expect(SettingsCategoryID.visibleCategories(
            scribeEnabled: true,
            granolaEnabled: false
        ) == [
            .general, .dictation, .scribe, .privacy, .advanced
        ])
        #expect(SettingsCategoryID.scribe.normalized(
            scribeEnabled: false,
            granolaEnabled: true
        ) == .general)
        #expect(SettingsCategoryID.meetings.normalized(
            scribeEnabled: true,
            granolaEnabled: false
        ) == .general)
        #expect(SettingsCategoryID.providers.normalized(
            scribeEnabled: true,
            granolaEnabled: true
        ) == .scribe)
        #expect(SettingsCategoryID.apps.normalized(
            scribeEnabled: false,
            granolaEnabled: false
        ) == .general)
        #expect(SettingsCategoryID.apps.normalized(
            scribeEnabled: true,
            granolaEnabled: false
        ) == .scribe)
        #expect(SettingsCategoryID.apps.normalized(
            scribeEnabled: false,
            granolaEnabled: true
        ) == .meetings)
        #expect(SettingsCategoryID.providers.normalized(
            scribeEnabled: false,
            granolaEnabled: true
        ) == .general)
    }

    @Test
    func legacyAppsSelectionIsDurablyMigratedIntoScribe() throws {
        let suite = "CadenceFeatureFlagTests.settings-migration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsPresentationStore(defaults: defaults, key: "settings")
        try store.save(.init(selectedCategory: .apps, isAdvancedExpanded: true))

        let result = store.loadNormalizingCategories(
            scribeEnabled: true,
            granolaEnabled: false
        )

        let expected = SettingsPresentationState(
            selectedCategory: .scribe,
            isAdvancedExpanded: true
        )
        #expect(result == .valid(expected))
        #expect(store.load() == .valid(expected))
    }

    @Test
    func onboardingOmitsScribeOnlyWhenTheMasterFlagIsOff() {
        #expect(!OnboardingStep.availableSteps(scribeEnabled: false).contains(.scribe))
        #expect(OnboardingStep.availableSteps(scribeEnabled: true).contains(.scribe))
        #expect(OnboardingStep.availableSteps(scribeEnabled: false).last == .ready)
    }
}
