import Foundation
import Testing
@testable import Cadence

struct CadenceFeatureFlagTests {
    @Test
    func scribeIsEnabledByDefault() throws {
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
    }

    @Test
    func productFeaturesCanBeEnabledWithDurableFeatureFlags() throws {
        let suite = "CadenceFeatureFlagTests.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CadenceFeatureFlags.scribeDefaultsKey)
        defaults.set(true, forKey: CadenceFeatureFlags.granolaDefaultsKey)

        let flags = CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: [:],
            arguments: []
        )

        #expect(flags.scribeEnabled)
        #expect(flags.granolaEnabled)
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
