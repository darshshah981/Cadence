import Foundation
import Testing
@testable import Cadence

/// U12 domain isolation: Apps reset, provider removal, and Settings presentation
/// mutations each touch only their owned durable keys.
struct ScribeDomainIsolationTests {
    @Test
    func resetAllApplicationsDoesNotMutateProviderOrSettingsBytes() async throws {
        let suite = "CadenceTests.DomainIsolation.Apps.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerKey = "domain.provider"
        let appsKey = "domain.apps"
        let settingsKey = "domain.settings"
        let providerStore = ScribeProviderLibraryStore(defaults: defaults, key: providerKey)
        let appsStore = ApplicationConfigurationStore(defaults: defaults, key: appsKey)
        let settingsStore = SettingsPresentationStore(defaults: defaults, key: settingsKey)

        let providerConfig = try makeProviderConfiguration()
        try providerStore.save(.init(
            revision: 1,
            configurations: [providerConfig],
            activeConfigurationID: providerConfig.id
        ))
        let appConfig = try makeApplicationConfiguration()
        try appsStore.save(.init(revision: 1, configurations: [appConfig]))
        try settingsStore.save(.init(selectedCategory: .providers, isAdvancedExpanded: true))

        let providerBytes = try #require(defaults.data(forKey: providerKey))
        let settingsBytes = try #require(defaults.data(forKey: settingsKey))
        let appsBytesBefore = try #require(defaults.data(forKey: appsKey))

        let writer = ApplicationConfigurationWriter(store: appsStore)
        try await writer.resetAllApplications()

        #expect(defaults.data(forKey: providerKey) == providerBytes)
        #expect(defaults.data(forKey: settingsKey) == settingsBytes)
        #expect(defaults.data(forKey: appsKey) != appsBytesBefore)
        guard case let .valid(library) = appsStore.load() else {
            Issue.record("Expected valid empty apps library after reset")
            return
        }
        #expect(library.configurations.isEmpty)
        guard case let .valid(providers) = providerStore.load() else {
            Issue.record("Expected provider library untouched")
            return
        }
        #expect(providers.configurations.count == 1)
        guard case let .valid(settings) = settingsStore.load() else {
            Issue.record("Expected settings presentation untouched")
            return
        }
        #expect(settings.selectedCategory == .providers)
    }

    @Test
    func clearingProviderLibraryDoesNotMutateAppsOrSettingsBytes() throws {
        let suite = "CadenceTests.DomainIsolation.Provider.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerKey = "domain.provider"
        let appsKey = "domain.apps"
        let settingsKey = "domain.settings"
        let providerStore = ScribeProviderLibraryStore(defaults: defaults, key: providerKey)
        let appsStore = ApplicationConfigurationStore(defaults: defaults, key: appsKey)
        let settingsStore = SettingsPresentationStore(defaults: defaults, key: settingsKey)

        let providerConfig = try makeProviderConfiguration()
        try providerStore.save(.init(
            revision: 2,
            configurations: [providerConfig],
            activeConfigurationID: providerConfig.id
        ))
        try appsStore.save(.init(revision: 3, configurations: [try makeApplicationConfiguration()]))
        try settingsStore.save(.init(selectedCategory: .apps, isAdvancedExpanded: false))

        let appsBytes = try #require(defaults.data(forKey: appsKey))
        let settingsBytes = try #require(defaults.data(forKey: settingsKey))

        // Removal of the only provider empties the library while preserving the
        // owned key namespace (marker-last migrations own their own keys).
        try providerStore.save(.init(revision: 3, configurations: [], activeConfigurationID: nil))

        #expect(defaults.data(forKey: appsKey) == appsBytes)
        #expect(defaults.data(forKey: settingsKey) == settingsBytes)
        guard case let .valid(providers) = providerStore.load() else {
            Issue.record("Expected empty valid provider library")
            return
        }
        #expect(providers.configurations.isEmpty)
        guard case let .valid(apps) = appsStore.load() else {
            Issue.record("Expected apps untouched")
            return
        }
        #expect(apps.configurations.count == 1)
    }

    @Test
    func settingsPresentationClearDoesNotMutateProviderOrAppsBytes() throws {
        let suite = "CadenceTests.DomainIsolation.Settings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let providerKey = "domain.provider"
        let appsKey = "domain.apps"
        let settingsKey = "domain.settings"
        let providerStore = ScribeProviderLibraryStore(defaults: defaults, key: providerKey)
        let appsStore = ApplicationConfigurationStore(defaults: defaults, key: appsKey)
        let settingsStore = SettingsPresentationStore(defaults: defaults, key: settingsKey)

        let providerConfig = try makeProviderConfiguration()
        try providerStore.save(.init(
            revision: 1,
            configurations: [providerConfig],
            activeConfigurationID: providerConfig.id
        ))
        try appsStore.save(.init(revision: 1, configurations: [try makeApplicationConfiguration()]))
        try settingsStore.save(.init(selectedCategory: .privacy, isAdvancedExpanded: true))

        let providerBytes = try #require(defaults.data(forKey: providerKey))
        let appsBytes = try #require(defaults.data(forKey: appsKey))

        settingsStore.clear()

        #expect(defaults.data(forKey: providerKey) == providerBytes)
        #expect(defaults.data(forKey: appsKey) == appsBytes)
        #expect(settingsStore.load() == .absent)
        #expect(defaults.data(forKey: settingsKey) == nil)
    }

    @Test
    func durableKeysAreDistinctAcrossProviderAppsSettingsAndGates() {
        let keys = [
            ScribeProviderLibraryStore.defaultKey,
            ApplicationConfigurationStore.defaultKey,
            SettingsPresentationStore.defaultKey,
            ScribePresetCatalogStateStore.defaultKey,
            AdaptiveScribeFeatureGateStore.defaultKey
        ]
        #expect(Set(keys).count == keys.count)
    }

    private func makeProviderConfiguration() throws -> ScribeProviderLibraryConfiguration {
        try ScribeProviderLibraryConfiguration(
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
            credentialReference: .init(rawValue: "credential-domain"),
            isEnabled: true
        )
    }

    private func makeApplicationConfiguration() throws -> ApplicationConfiguration {
        try ApplicationConfiguration(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            application: ApplicationReference(
                id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                lastKnownBundleURL: URL(fileURLWithPath: "/Applications/Slack.app"),
                lastKnownDisplayName: "Slack"
            ),
            isEnabled: true,
            familyID: .messaging,
            presetSelection: .familyDefault,
            customGuidance: nil,
            revision: 1
        )
    }
}
