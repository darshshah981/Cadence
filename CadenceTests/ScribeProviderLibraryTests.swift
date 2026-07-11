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

    @Test
    func missingConsentBackwardDecodesButMaterialMismatchRejectsStrictly() throws {
        let fixture = try ProviderStoreFixture()
        defer { fixture.cleanUp() }
        let base = try fixture.configuration(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .openAIDirect,
            modelID: "gpt-test"
        )
        let noConsent = ScribeProviderLibrary(
            revision: 1, configurations: [base], activeConfigurationID: base.id
        )
        try fixture.store.save(noConsent)
        guard case let .valid(decoded) = fixture.store.load() else {
            Issue.record("Expected backward-readable configuration"); return
        }
        #expect(decoded.configurations.first?.consentReceipt == nil)

        let wrongReceipt = ScribeProviderConsentIssuer.issue(
            providerKind: .openAIDirect,
            recipientOrigin: "https://wrong.example",
            routingPolicy: .directSingleModel,
            retentionPolicy: .requestStorageDisabled,
            dataPolicy: .providerPolicyApplies,
            disclosureRevision: base.disclosureVersion,
            acceptedAt: base.acceptedAt
        )
        let invalid = try ScribeProviderLibraryConfiguration(
            id: base.id, kind: base.kind, displayName: base.displayName,
            normalizedOrigin: base.normalizedOrigin, baseURL: base.baseURL,
            requestURL: base.requestURL, selectedModelID: base.selectedModelID,
            catalogID: base.catalogID, disclosureVersion: base.disclosureVersion,
            acceptedAt: base.acceptedAt, lastValidatedAt: base.lastValidatedAt,
            credentialReference: base.credentialReference, isEnabled: true,
            credentialStorageDomain: .candidate, consentReceipt: wrongReceipt
        )
        #expect(throws: StrictPersistenceError.invalidValue) {
            try fixture.store.save(ScribeProviderLibrary(
                revision: 2, configurations: [invalid], activeConfigurationID: invalid.id
            ))
        }
    }

    @Test
    func cleanupLedgerIsBoundedAndRejectsFutureOrMalformedValues() throws {
        let suite = "CadenceTests.CleanupLedger.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ScribeCredentialCleanupLedgerStore(defaults: defaults, key: "ledger")
        let reference = ScribeStoredCredentialReference(
            domain: .candidate, opaqueReference: .init(rawValue: "opaque")
        )
        let valid = ScribeCredentialCleanupLedger(revision: 1, references: [reference])
        try store.save(valid)
        #expect(store.load() == .valid(valid))

        defaults.set(try JSONEncoder().encode(ScribeCredentialCleanupLedger(
            schemaVersion: 999, revision: 1, references: [reference]
        )), forKey: "ledger")
        #expect(store.load() == .rejected)
    }

    @Test
    func cleanupLedgerRestoresPreviousBytesWhenSetOrRemovalFails() throws {
        let bytes = FailingLedgerBytes()
        let store = ScribeCredentialCleanupLedgerStore(bytes: bytes, key: "ledger")
        let first = ScribeCredentialCleanupLedger(revision: 1, references: [
            ScribeStoredCredentialReference(
                domain: .candidate, opaqueReference: .init(rawValue: "first")
            )
        ])
        try store.save(first)
        let original = bytes.value

        bytes.failNextSetAfterMutation = true
        #expect(throws: LedgerBytesFailure.injected) {
            try store.save(ScribeCredentialCleanupLedger(revision: 2, references: []))
        }
        #expect(bytes.value == original)
        #expect(store.load() == .valid(first))

        bytes.failNextRemoveAfterMutation = true
        #expect(throws: LedgerBytesFailure.injected) { try store.save(nil) }
        #expect(bytes.value == original)
        #expect(store.load() == .valid(first))
    }

    @Test
    func rejectedCleanupLedgerBlocksOverwriteAndPreservesBytes() throws {
        let bytes = FailingLedgerBytes()
        bytes.value = Data("future-or-corrupt".utf8)
        let original = bytes.value
        let store = ScribeCredentialCleanupLedgerStore(bytes: bytes, key: "ledger")
        #expect(store.load() == .rejected)
        #expect(throws: ScribeProviderConnectionError.retainedStoreUnreadable) {
            try store.save(ScribeCredentialCleanupLedger(revision: 1, references: []))
        }
        #expect(bytes.value == original)
    }
}

private enum LedgerBytesFailure: Error { case injected }

private final class FailingLedgerBytes: ScribeCleanupLedgerBytesPersisting {
    var value: Data?
    var failNextSetAfterMutation = false
    var failNextRemoveAfterMutation = false
    func data(forKey key: String) -> Data? { value }
    func set(_ data: Data, forKey key: String) throws {
        value = data
        if failNextSetAfterMutation {
            failNextSetAfterMutation = false
            throw LedgerBytesFailure.injected
        }
    }
    func remove(forKey key: String) throws {
        value = nil
        if failNextRemoveAfterMutation {
            failNextRemoveAfterMutation = false
            throw LedgerBytesFailure.injected
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
