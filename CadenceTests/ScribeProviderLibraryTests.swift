import Foundation
import Testing
@testable import Cadence

struct ScribeProviderLibraryTests {
    @Test
    func emptyStoreIsAbsentAndValidLibraryRoundTripsSemantically() throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.store.load() == .absent)

        let configuration = try fixture.configuration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            modelID: "gpt-test"
        )
        let library = ScribeProviderLibrary(
            revision: 4,
            configurations: [configuration],
            activeConfigurationID: configuration.id
        )

        try fixture.store.save(library)

        #expect(fixture.store.load() == .valid(library.normalized()))
        #expect(fixture.defaults.data(forKey: fixture.key) != nil)
    }

    @Test
    func storeRejectsFutureMalformedDuplicateAndInvalidActiveEnvelopesWithoutChangingBytes() throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.configuration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            modelID: "gpt-test"
        )
        let second = try fixture.configuration(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            kind: .openAIDirect,
            modelID: "gpt-other"
        )

        let cases: [(Data, ScribeProviderLibraryRejection)] = [
            (Data("not-json".utf8), .malformed),
            (try JSONEncoder().encode(ScribeProviderLibraryEnvelope(
                schemaVersion: 999,
                library: .init(revision: 1, configurations: [first], activeConfigurationID: first.id)
            )), .futureSchema),
            (try JSONEncoder().encode(ScribeProviderLibraryEnvelope(
                library: .init(revision: 1, configurations: [first, first], activeConfigurationID: first.id)
            )), .duplicateConfigurationID),
            (try JSONEncoder().encode(ScribeProviderLibraryEnvelope(
                library: .init(revision: 1, configurations: [first, second], activeConfigurationID: first.id)
            )), .duplicateProviderKind),
            (try JSONEncoder().encode(ScribeProviderLibraryEnvelope(
                library: .init(revision: 1, configurations: [first], activeConfigurationID: UUID())
            )), .invalidActiveConfigurationID)
        ]

        for (bytes, rejection) in cases {
            fixture.defaults.set(bytes, forKey: fixture.key)
            #expect(fixture.store.load() == .rejected(rejection))
            #expect(fixture.defaults.data(forKey: fixture.key) == bytes)
            #expect(fixture.store.referencedCredentials() == .unavailable)
        }
    }

    @Test
    func disabledActiveAndInvalidProviderFieldsRejectTheCompleteLibrary() throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanUp() }
        let valid = try fixture.configuration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            modelID: "gpt-test"
        )
        let disabled = valid.withEnabled(false)
        let invalidOrigin = valid.withOrigin("https://example.com")

        for (configuration, rejection) in [
            (disabled, ScribeProviderLibraryRejection.disabledActiveConfiguration),
            (invalidOrigin, ScribeProviderLibraryRejection.invalidConfiguration)
        ] {
            let envelope = ScribeProviderLibraryEnvelope(library: .init(
                revision: 1,
                configurations: [configuration],
                activeConfigurationID: configuration.id
            ))
            let bytes = try JSONEncoder().encode(envelope)
            fixture.defaults.set(bytes, forKey: fixture.key)
            #expect(fixture.store.load() == .rejected(rejection))
            #expect(fixture.defaults.data(forKey: fixture.key) == bytes)
        }
    }

    @Test
    func optionalCatalogIDNormalizesAndRejectsOversizedOrControlValues() throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanUp() }
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

        let spaced = try fixture.configuration(id: id, kind: .openAIDirect, modelID: "gpt-test", catalogID: "  release.test  ")
        try fixture.store.save(.init(revision: 1, configurations: [spaced], activeConfigurationID: id))
        guard case let .valid(normalized) = fixture.store.load() else {
            Issue.record("Expected valid normalized provider library")
            return
        }
        #expect(normalized.configurations.first?.catalogID == "release.test")

        for catalogID in [
            String(repeating: "a", count: ScribeProviderLibraryConfiguration.maximumCatalogIDUTF8Bytes + 1),
            "release\u{0000}test"
        ] {
            let invalid = try fixture.configuration(id: id, kind: .openAIDirect, modelID: "gpt-test", catalogID: catalogID)
            let bytes = try JSONEncoder().encode(ScribeProviderLibraryEnvelope(library: .init(
                revision: 1,
                configurations: [invalid],
                activeConfigurationID: id
            )))
            fixture.defaults.set(bytes, forKey: fixture.key)
            #expect(fixture.store.load() == .rejected(.invalidConfiguration))
            #expect(fixture.defaults.data(forKey: fixture.key) == bytes)
        }
    }
}

private struct ProviderStoreFixture {
    let suite: String
    let defaults: UserDefaults
    let key = "CadenceTests.providerLibrary.owned-by-fixture"
    let store: ScribeProviderLibraryStore

    init() throws {
        suite = "CadenceTests.ProviderLibrary.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        store = ScribeProviderLibraryStore(defaults: defaults, key: key)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    func configuration(
        id: UUID,
        kind: ScribeProviderKind,
        modelID: String,
        catalogID: String? = nil
    ) throws -> ScribeProviderLibraryConfiguration {
        try ScribeProviderLibraryConfiguration(
            id: id,
            kind: kind,
            displayName: " OpenAI ",
            normalizedOrigin: "https://api.openai.com",
            baseURL: URL(string: "https://api.openai.com")!,
            requestURL: URL(string: "https://api.openai.com/v1/responses")!,
            selectedModelID: modelID,
            catalogID: catalogID,
            disclosureVersion: 2,
            acceptedAt: Date(timeIntervalSince1970: 10),
            lastValidatedAt: Date(timeIntervalSince1970: 20),
            credentialReference: .init(rawValue: "credential-openai"),
            isEnabled: true
        )
    }
}
