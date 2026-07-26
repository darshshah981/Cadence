import Foundation
import Testing
@testable import Cadence

private extension AdaptiveScribeReaderValidity {
    func withProviderLibrary(_ value: DurableReaderValidity) -> Self {
        .init(
            providerLibrary: value,
            applicationConfigurations: applicationConfigurations,
            presetCatalogState: presetCatalogState,
            settingsPresentation: settingsPresentation
        )
    }

    func withApplicationConfigurations(_ value: DurableReaderValidity) -> Self {
        .init(
            providerLibrary: providerLibrary,
            applicationConfigurations: value,
            presetCatalogState: presetCatalogState,
            settingsPresentation: settingsPresentation
        )
    }

    func withSettingsPresentation(_ value: DurableReaderValidity) -> Self {
        .init(
            providerLibrary: providerLibrary,
            applicationConfigurations: applicationConfigurations,
            presetCatalogState: presetCatalogState,
            settingsPresentation: value
        )
    }
}

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

    @Test
    func enabledBuildPromotesOnlyTheMigrationBaselineToCompletedRuntimeGates() throws {
        let suite = "CadenceTests.FeatureGates.BuildRollout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AdaptiveScribeFeatureGateStore(defaults: defaults, key: "gates")

        try store.save(.migrationBaseline)
        try store.promoteMigrationBaselineIfScribeEnabled(true)
        #expect(store.load() == .valid(.allEnabled))

        try store.save(.allDisabled)
        try store.promoteMigrationBaselineIfScribeEnabled(true)
        #expect(store.load() == .valid(.allDisabled))
    }

    @Test
    func everyReaderRequiresItsOwnSupportedMarkerAndFreshSemanticValidation() throws {
        let suite = "CadenceTests.LiveReaders.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = ScribeProviderLibraryStore(defaults: defaults, key: "provider")
        let applications = ApplicationConfigurationStore(defaults: defaults, key: "applications")
        let presets = ScribePresetCatalogStateStore(defaults: defaults, key: "presets")
        let settings = SettingsPresentationStore(defaults: defaults, key: "settings")
        let gates = AdaptiveScribeFeatureGateStore(defaults: defaults, key: "gates")
        let markers = AdaptiveScribeMigrationMarkerStore(defaults: defaults, keyPrefix: "marker")
        let service = AdaptiveScribeLiveReaderService(
            providerStore: provider,
            applicationStore: applications,
            presetStore: presets,
            settingsStore: settings,
            featureGateStore: gates,
            markerStore: markers
        )
        let providerConfiguration = try ScribeProviderLibraryConfiguration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            displayName: "OpenAI",
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: "gpt-test",
            catalogID: nil,
            disclosureVersion: 2,
            acceptedAt: Date(timeIntervalSince1970: 10),
            lastValidatedAt: Date(timeIntervalSince1970: 20),
            credentialReference: .init(rawValue: "credential"),
            isEnabled: true
        )
        try provider.save(.init(
            revision: 1,
            configurations: [providerConfiguration],
            activeConfigurationID: providerConfiguration.id
        ))
        try applications.save(.init(revision: 1, configurations: []))
        try presets.save(.generalNeutral)
        try settings.save(.init(selectedCategory: .general, isAdvancedExpanded: false))
        try gates.save(.allEnabled)

        #expect(service.load().scribeAvailability == .setupRequired)
        for domain in AdaptiveScribeMigrationDomain.allCases {
            try markers.markComplete(domain)
        }
        #expect(service.load().readers.providerLibrary == .valid)
        #expect(service.load().scribeAvailability == .setupRequired)
        let completedRuntime = AdaptiveScribeLiveReaderService(
            providerStore: provider,
            applicationStore: applications,
            presetStore: presets,
            settingsStore: settings,
            featureGateStore: gates,
            markerStore: markers,
            polishedDictationRuntimeAvailable: true
        )
        #expect(completedRuntime.load().scribeAvailability == .enabled)

        defaults.set(Data("bad".utf8), forKey: "presets")
        let invalidated = service.load()
        #expect(invalidated.readers.presetCatalogState == .rejected)
        #expect(!invalidated.eligibility.adaptiveScribeEnabled)
        #expect(invalidated.scribeAvailability == .setupRequired)
    }

    @Test
    func disablingReadersPreservesAllBytesAndNeverFallsBackToRetiredIntent() throws {
        let suite = "CadenceTests.ReaderRollback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gateStore = AdaptiveScribeFeatureGateStore(defaults: defaults, key: "gates")
        let disabled = AdaptiveScribeFeatureGates(
            providerLibraryV2: false,
            applicationIntelligenceV2: false,
            settingsControlSystemV2: false,
            polishedDictationV2: false,
            adaptiveScribeV2: false
        )
        try gateStore.save(disabled)
        let before = try #require(defaults.data(forKey: "gates"))

        let eligibility = disabled.eligibility(readers: .init(
            providerLibrary: .valid,
            applicationConfigurations: .valid,
            presetCatalogState: .valid,
            settingsPresentation: .valid
        ))

        #expect(!eligibility.adaptiveScribeEnabled)
        #expect(defaults.data(forKey: "gates") == before)
        #expect(AdaptiveScribeAvailability(eligibility: eligibility) == .setupRequired)
    }

    @Test
    @MainActor
    func appModelEntryGateBlocksIntentAndRequestsCoordinatorCancellation() {
        var events: [String] = []

        let allowed = AppModel.enforceAdaptiveScribeEntry(
            availability: .setupRequired,
            cancelActiveCoordinator: { events.append("coordinator-cancelled") },
            presentSetup: { events.append("setup-presented") }
        )

        #expect(!allowed)
        #expect(events == ["coordinator-cancelled", "setup-presented"])
        #expect(!events.contains("intent-picker"))
    }
}
