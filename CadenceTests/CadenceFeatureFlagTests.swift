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
    }

    @Test
    func scribeCanBeEnabledWithTheDurableFeatureFlag() throws {
        let suite = "CadenceFeatureFlagTests.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CadenceFeatureFlags.scribeDefaultsKey)

        let flags = CadenceFeatureFlags.resolve(
            defaults: defaults,
            environment: [:],
            arguments: []
        )

        #expect(flags.scribeEnabled)
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
    }

    @Test
    func settingsCategoriesHideScribeAndNormalizeLegacySelections() {
        #expect(SettingsCategoryID.visibleCategories(scribeEnabled: false) == [
            .general, .dictation, .meetings, .apps, .privacy, .advanced
        ])
        #expect(SettingsCategoryID.visibleCategories(scribeEnabled: true) == [
            .general, .dictation, .scribe, .meetings, .apps, .privacy, .advanced
        ])
        #expect(SettingsCategoryID.scribe.normalized(scribeEnabled: false) == .general)
        #expect(SettingsCategoryID.providers.normalized(scribeEnabled: true) == .apps)
    }

    @Test
    func onboardingOmitsScribeOnlyWhenTheMasterFlagIsOff() {
        #expect(!OnboardingStep.availableSteps(scribeEnabled: false).contains(.scribe))
        #expect(OnboardingStep.availableSteps(scribeEnabled: true).contains(.scribe))
        #expect(OnboardingStep.availableSteps(scribeEnabled: false).last == .ready)
    }
}
