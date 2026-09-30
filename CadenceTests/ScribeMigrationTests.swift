import Foundation
import Testing
@testable import Cadence

struct ScribeMigrationTests {
    @Test
    func freshInstallDefaultsToOnDeviceWithoutCredentialsAndRemovalPersists() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.migration().migrate(.absent)
        guard case let .valid(library) = fixture.providerStore.load() else {
            Issue.record("Expected the built-in default"); return
        }
        let local = try #require(library.configurations.first)
        #expect(library.configurations.count == 1)
        #expect(library.activeConfigurationID == local.id)
        #expect(local.kind == .legacyLocal)
        #expect(local.consentReceipt == nil)
        #expect(local.credentialStorageDomain == nil)
        #expect(ScribeProviderLibraryConfigurationValidator.isValid(local))

        try fixture.providerStore.save(.init(
            revision: 2, configurations: [], activeConfigurationID: nil
        ))
        #expect(try fixture.migration().migrate(.absent) == .alreadyComplete)
        guard case let .valid(removed) = fixture.providerStore.load() else {
            Issue.record("Expected retained removal"); return
        }
        #expect(removed.configurations.isEmpty)
    }

    @Test(arguments: [
        AdaptiveScribeMigrationPoint.afterDestinationWrite,
        .afterSemanticReadback, .beforeMarkerWrite
    ])
    func onDeviceDefaultResumesInterruptedFirstLaunch(point: AdaptiveScribeMigrationPoint) throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        #expect(throws: MigrationInterruption.self) {
            try fixture.migration(interrupt: { observed in
                if observed == point { throw MigrationInterruption() }
            }).migrate(.absent)
        }
        let bytes = fixture.defaults.data(forKey: fixture.providerKey)
        _ = try fixture.migration().migrate(.absent)
        #expect(fixture.defaults.data(forKey: fixture.providerKey) == bytes)
        #expect(fixture.markerStore.load(.providerLibrary) == .valid)
    }

    @Test
    func disabledCloudChoiceNeverBecomesOnDeviceDefault() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        var cloud = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "retained-cloud"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        cloud.isEnabled = false
        _ = try fixture.migration().migrate(.valid(cloud))
        guard case let .valid(library) = fixture.providerStore.load() else {
            Issue.record("Expected retained cloud choice"); return
        }
        #expect(library.configurations.map(\.kind) == [.deepSeek])
        #expect(library.activeConfigurationID == nil)
        #expect(library.configurations.first?.isEnabled == false)
    }

    @Test
    func completedMarkerTrustsFreshValidDestinationWithoutReplayingLegacySource() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        let legacy = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-keychain-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        _ = try fixture.migration().migrate(.valid(legacy))
        guard case let .valid(library) = fixture.providerStore.load(),
              let original = library.configurations.first else {
            Issue.record("Expected migrated provider")
            return
        }
        let edited = try ScribeProviderLibraryConfiguration(
            id: original.id,
            kind: original.kind,
            displayName: "User renamed provider",
            normalizedOrigin: original.normalizedOrigin,
            baseURL: original.baseURL,
            requestURL: original.requestURL,
            selectedModelID: original.selectedModelID,
            catalogID: original.catalogID,
            disclosureVersion: original.disclosureVersion,
            acceptedAt: original.acceptedAt,
            lastValidatedAt: original.lastValidatedAt,
            credentialReference: original.credentialReference,
            isEnabled: original.isEnabled
        )
        try fixture.providerStore.save(.init(
            revision: library.revision + 1,
            configurations: [edited],
            activeConfigurationID: edited.id
        ))

        #expect(try fixture.migration().migrate(.rejected(.malformed)) == .alreadyComplete)
        guard case let .valid(reloaded) = fixture.providerStore.load() else {
            Issue.record("Expected edited provider")
            return
        }
        #expect(reloaded.configurations.first?.displayName == "User renamed provider")
    }

    @Test
    func completedMarkerWithCorruptDestinationFailsClosedWithoutChangingEitherStore() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        let legacy = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-keychain-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        _ = try fixture.migration().migrate(.valid(legacy))
        let source = try JSONEncoder().encode(ScribeProviderConfigurationEnvelope(configuration: legacy))
        let corrupt = Data("corrupt-destination".utf8)
        fixture.defaults.set(source, forKey: fixture.legacyKey)
        fixture.defaults.set(corrupt, forKey: fixture.providerKey)

        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.valid(legacy))
        }
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == source)
        #expect(fixture.defaults.data(forKey: fixture.providerKey) == corrupt)
    }

    @Test
    func malformedLegacyAndFutureDestinationArePreservedWithoutMarkers() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        let malformed = Data("malformed-source".utf8)
        fixture.defaults.set(malformed, forKey: fixture.legacyKey)
        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.rejected(.malformed))
        }
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == malformed)
        #expect(fixture.markerStore.load(.providerLibrary) == .absent)

        let legacy = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-keychain-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        let future = try JSONEncoder().encode(ScribeProviderLibraryEnvelope(
            schemaVersion: 999,
            library: .init(revision: 1, configurations: [], activeConfigurationID: nil)
        ))
        fixture.defaults.set(future, forKey: fixture.providerKey)
        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.valid(legacy))
        }
        #expect(fixture.defaults.data(forKey: fixture.providerKey) == future)
        #expect(fixture.markerStore.load(.providerLibrary) == .absent)
    }

    @Test(arguments: [
        AdaptiveScribeMigrationPoint.beforeDestinationWrite,
        .afterDestinationWrite,
        .afterSemanticReadback,
        .beforeMarkerWrite
    ])
    func migrationResumesAtEveryMarkerLastInterruptionBoundary(
        point: AdaptiveScribeMigrationPoint
    ) throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        let legacy = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-keychain-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        var stopped = false

        #expect(throws: MigrationInterruption.self) {
            try fixture.migration(interrupt: { observed in
                guard observed == point, !stopped else { return }
                stopped = true
                throw MigrationInterruption()
            }).migrate(.valid(legacy))
        }
        #expect(fixture.markerStore.load(.providerLibrary) == .absent)

        _ = try fixture.migration().migrate(.valid(legacy))
        guard case let .valid(library) = fixture.providerStore.load() else {
            Issue.record("Expected resumed destination")
            return
        }
        #expect(library.configurations.count == 1)
        #expect(fixture.markerStore.load(.providerLibrary) == .valid)
    }

    @Test
    func legacyProviderMigrationIsMarkerLastIdempotentAndPreservesSourceBytes() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        let legacy = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-keychain-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        try fixture.legacyStore.save(legacy)
        let legacyBytes = try #require(fixture.defaults.data(forKey: fixture.legacyKey))
        var stopped = false

        #expect(throws: MigrationInterruption.self) {
            try fixture.migration(interrupt: { point in
                guard point == .afterDestinationWrite, !stopped else { return }
                stopped = true
                throw MigrationInterruption()
            }).migrate(.valid(legacy))
        }
        #expect(fixture.markerStore.load(.providerLibrary) == .absent)
        #expect(fixture.providerStore.load().readerValidity == .valid)

        let first = try fixture.migration().migrate(.valid(legacy))
        let migratedBytes = try #require(fixture.defaults.data(forKey: fixture.providerKey))
        let second = try fixture.migration().migrate(.valid(legacy))

        #expect(first == .migrated)
        #expect(second == .alreadyComplete)
        #expect(fixture.markerStore.load(.providerLibrary) == .valid)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == legacyBytes)
        #expect(fixture.defaults.data(forKey: fixture.providerKey) == migratedBytes)
        guard case let .valid(library) = fixture.providerStore.load(),
              let migrated = library.configurations.first else {
            Issue.record("Expected one migrated provider")
            return
        }
        #expect(library.configurations.count == 1)
        #expect(library.activeConfigurationID == migrated.id)
        #expect(migrated.kind == .deepSeek)
        #expect(migrated.credentialReference == legacy.credentialReference)
        #expect(migrated.selectedModelID == legacy.modelID)
    }

    @Test
    func markerDoesNotOverrideFreshDestinationValidationAndReaderOffPreservesBytes() throws {
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        let legacy = try ScribeProviderConfiguration.deepSeek(
            credentialReference: .init(rawValue: "legacy-keychain-reference"),
            acceptedAt: Date(timeIntervalSince1970: 10)
        )
        try fixture.legacyStore.save(legacy)
        _ = try fixture.migration().migrate(.valid(legacy))
        let legacyBytes = try #require(fixture.defaults.data(forKey: fixture.legacyKey))
        let destinationBytes = try #require(fixture.defaults.data(forKey: fixture.providerKey))
        fixture.defaults.set(Data("corrupt".utf8), forKey: fixture.providerKey)

        let state = fixture.liveReaderService().load()

        #expect(state.readers.providerLibrary == .rejected)
        #expect(!state.eligibility.adaptiveScribeEnabled)
        #expect(state.scribeAvailability == .setupRequired)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == legacyBytes)
        #expect(destinationBytes != fixture.defaults.data(forKey: fixture.providerKey))
    }

    @Test
    func retainedLegacyProviderGoldenBytesRemainDecodable() throws {
        let data = try Data(contentsOf: adaptiveScribeFixture("legacy-provider-library.json"))
        let fixture = try ProviderMigrationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(data, forKey: fixture.legacyKey)
        let legacy = fixture.legacyStore.load()
        _ = try fixture.migration().migrate(legacy)
        let envelope = try JSONDecoder().decode(ScribeProviderConfigurationEnvelope.self, from: data)

        #expect(envelope.schemaVersion == ScribeProviderConfigurationEnvelope.currentSchemaVersion)
        #expect(envelope.configuration.kind == .deepSeek)
        #expect(envelope.configuration.credentialReference.rawValue == "legacy-keychain-reference")
        #expect(fixture.legacyStore.load() == legacy)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == data)
    }

}

private struct MigrationInterruption: Error {}

private func adaptiveScribeFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/AdaptiveScribe")
        .appendingPathComponent(name)
}

private struct ProviderMigrationFixture {
    let suite: String
    let defaults: UserDefaults
    let legacyKey = "legacy-provider"
    let providerKey = "provider-v2"
    let markerPrefix = "markers"
    let gatesKey = "gates"
    let legacyStore: ScribeProviderConfigurationStore
    let providerStore: ScribeProviderLibraryStore
    let markerStore: AdaptiveScribeMigrationMarkerStore

    init() throws {
        suite = "CadenceTests.ProviderMigration.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        legacyStore = ScribeProviderConfigurationStore(defaults: defaults, key: legacyKey)
        providerStore = ScribeProviderLibraryStore(defaults: defaults, key: providerKey)
        markerStore = AdaptiveScribeMigrationMarkerStore(defaults: defaults, keyPrefix: markerPrefix)
    }

    func migration(
        interrupt: @escaping (AdaptiveScribeMigrationPoint) throws -> Void = { _ in }
    ) -> ProviderLibraryMigrationService {
        ProviderLibraryMigrationService(
            destinationStore: providerStore,
            markerStore: markerStore,
            makeID: { UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")! },
            interrupt: interrupt
        )
    }

    func liveReaderService() -> AdaptiveScribeLiveReaderService {
        AdaptiveScribeLiveReaderService(
            providerStore: providerStore,
            applicationStore: ApplicationConfigurationStore(defaults: defaults, key: "apps"),
            presetStore: ScribePresetCatalogStateStore(defaults: defaults, key: "presets"),
            settingsStore: SettingsPresentationStore(defaults: defaults, key: "settings"),
            featureGateStore: AdaptiveScribeFeatureGateStore(defaults: defaults, key: gatesKey),
            markerStore: markerStore
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}
