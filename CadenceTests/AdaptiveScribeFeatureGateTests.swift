import Foundation
import Testing
@testable import Cadence

struct AdaptiveScribeFeatureGateTests {
    @Test
    func independentStoresOwnInjectedDurableKeysAndRoundTripWithoutSynthesizingState() throws {
        #expect(ScribeProviderLibraryStore.defaultKey == CadenceDurablePreferenceKeys.providerLibrary)
        #expect(ApplicationConfigurationStore.defaultKey == CadenceDurablePreferenceKeys.applicationConfigurations)
        #expect(ScribePresetCatalogStateStore.defaultKey == CadenceDurablePreferenceKeys.presetCatalogState)
        #expect(SettingsPresentationStore.defaultKey == CadenceDurablePreferenceKeys.settingsPresentation)
        #expect(AdaptiveScribeFeatureGateStore.defaultKey == CadenceDurablePreferenceKeys.featureGates)
        #expect(Set([
            ScribeProviderLibraryStore.defaultKey,
            ApplicationConfigurationStore.defaultKey,
            ScribePresetCatalogStateStore.defaultKey,
            SettingsPresentationStore.defaultKey,
            AdaptiveScribeFeatureGateStore.defaultKey
        ]).count == 5)

        let suite = "CadenceTests.IndependentStores.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presetStore = ScribePresetCatalogStateStore(defaults: defaults, key: "preset")
        let settingsStore = SettingsPresentationStore(defaults: defaults, key: "settings")

        #expect(presetStore.load() == .absent)
        #expect(settingsStore.load() == .absent)
        try presetStore.save(.generalNeutral)
        let settings = SettingsPresentationState(selectedCategory: .providers, isAdvancedExpanded: true)
        try settingsStore.save(settings)
        #expect(presetStore.load() == .valid(.generalNeutral))
        #expect(settingsStore.load() == .valid(settings))
    }

    @Test
    func presetStoreRejectsUnknownCatalogRevisionAndReaderRemainsInvalid() throws {
        let suite = "CadenceTests.PresetRevision.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "preset"
        let store = ScribePresetCatalogStateStore(defaults: defaults, key: key)
        let unknown = ScribePresetCatalogState(
            catalogRevision: 2,
            fallbackFamilyID: .general,
            fallbackPresetID: ScribePresetCatalogState.generalNeutral.fallbackPresetID
        )
        let bytes = try JSONEncoder().encode(ScribePresetCatalogStateEnvelope(state: unknown))
        defaults.set(bytes, forKey: key)

        #expect(store.load() == .rejected(.unsupportedCatalogRevision))
        #expect(store.load().readerValidity == .rejected)
        #expect(defaults.data(forKey: key) == bytes)
    }

    @Test
    func absentAndRejectedGateStoresAreTypedAndPreserveBytes() throws {
        let suite = "CadenceTests.FeatureGates.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "CadenceTests.featureGates.owned-by-fixture"
        let store = AdaptiveScribeFeatureGateStore(defaults: defaults, key: key)

        #expect(store.load() == .absent)
        let malformed = Data("bad".utf8)
        defaults.set(malformed, forKey: key)
        #expect(store.load() == .rejected(.malformed))
        #expect(defaults.data(forKey: key) == malformed)
    }

    @Test
    func masterEligibilityRequiresEnabledDependenciesAndLiveValidReaders() {
        let enabled = AdaptiveScribeFeatureGates.allEnabled
        let validReaders = AdaptiveScribeReaderValidity(
            providerLibrary: .valid,
            applicationConfigurations: .valid,
            presetCatalogState: .valid,
            settingsPresentation: .valid
        )

        #expect(enabled.eligibility(readers: validReaders).adaptiveScribeEnabled)
        #expect(!enabled.eligibility(readers: validReaders.withProviderLibrary(.rejected)).adaptiveScribeEnabled)
        #expect(!enabled.withPolishedDictation(false).eligibility(readers: validReaders).adaptiveScribeEnabled)
        #expect(enabled.eligibility(readers: validReaders.withSettingsPresentation(.rejected)).adaptiveScribeEnabled)
        #expect(!enabled.eligibility(readers: validReaders.withApplicationConfigurations(.absent)).adaptiveScribeEnabled)
    }

    @Test
    func featureGateEnvelopeRoundTripsSemanticallyUsingInjectedKey() throws {
        let suite = "CadenceTests.FeatureGates.RoundTrip.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "CadenceTests.featureGates.roundtrip"
        let store = AdaptiveScribeFeatureGateStore(defaults: defaults, key: key)

        try store.save(.allEnabled)

        #expect(store.load() == .valid(.allEnabled))
        #expect(defaults.data(forKey: key) != nil)
    }
}
