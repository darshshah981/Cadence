import Foundation
import Testing
@testable import Cadence

struct ApplicationConfigurationTests {
    @Test
    func absentStoreHasSafeFallbackAndValidLibraryRoundTrips() throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.store.load() == .absent)
        #expect(fixture.store.safeResolution == .generalNeutral)

        let configuration = try fixture.configuration()
        let library = ApplicationConfigurationLibrary(revision: 3, configurations: [configuration])
        try fixture.store.save(library)

        #expect(fixture.store.load() == .valid(library.normalized()))
    }

    @Test
    func malformedFutureDuplicateAndInvalidFieldsRejectWholeEnvelopeAndPreserveBytes() throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let configuration = try fixture.configuration()
        let duplicateReference = try fixture.configuration(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let future = try JSONEncoder().encode(ApplicationConfigurationEnvelope(
            schemaVersion: 999,
            library: .init(revision: 1, configurations: [configuration])
        ))
        let duplicateIDs = try JSONEncoder().encode(ApplicationConfigurationEnvelope(
            library: .init(revision: 1, configurations: [configuration, configuration])
        ))
        let duplicateReferences = try JSONEncoder().encode(ApplicationConfigurationEnvelope(
            library: .init(revision: 1, configurations: [configuration, duplicateReference])
        ))

        for (bytes, rejection) in [
            (Data("bad".utf8), ApplicationConfigurationRejection.malformed),
            (future, .futureSchema),
            (duplicateIDs, .duplicateConfigurationID),
            (duplicateReferences, .duplicateApplicationReference)
        ] {
            fixture.defaults.set(bytes, forKey: fixture.key)
            #expect(fixture.store.load() == .rejected(rejection))
            #expect(fixture.store.safeResolution == .generalNeutral)
            #expect(fixture.defaults.data(forKey: fixture.key) == bytes)
        }
    }

    @Test
    func duplicateReferencesAreComparedAfterCanonicalNormalization() throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.configuration()
        let equivalent = try ApplicationConfiguration(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            application: ApplicationReference(
                id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                bundleIdentifier: "  com.tinyspeck.slackmacgap  ",
                lastKnownBundleURL: URL(fileURLWithPath: "/Applications/Utilities/../Slack.app"),
                lastKnownDisplayName: "Slack"
            ),
            isEnabled: true,
            familyID: .messaging,
            presetSelection: .familyDefault,
            customGuidance: nil,
            revision: 1
        )
        let bytes = try JSONEncoder().encode(ApplicationConfigurationEnvelope(
            library: .init(revision: 1, configurations: [first, equivalent])
        ))
        fixture.defaults.set(bytes, forKey: fixture.key)

        #expect(fixture.store.load() == .rejected(.duplicateApplicationReference))
        #expect(fixture.defaults.data(forKey: fixture.key) == bytes)
    }

    @Test
    func customGuidanceNormalizesWhitespaceAndEnforcesByteAndControlBoundaries() throws {
        #expect(try ScribeCustomGuidance("  Use British spelling.\n  ").rawValue == "Use British spelling.")
        #expect(try ScribeCustomGuidance(String(repeating: "é", count: 1_000)).rawValue.utf8.count == 2_000)
        #expect(throws: ApplicationConfigurationValidationError.guidanceTooLarge) {
            try ScribeCustomGuidance(String(repeating: "é", count: 1_001))
        }
        #expect(throws: ApplicationConfigurationValidationError.invalidGuidance) {
            try ScribeCustomGuidance("Do this\u{0000}")
        }
    }

    @Test
    func persistedEnvelopeContainsNoRuntimeIdentityOrIconSurface() throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        try fixture.store.save(.init(revision: 1, configurations: [try fixture.configuration()]))
        let bytes = try #require(fixture.defaults.data(forKey: fixture.key))
        let text = try #require(String(data: bytes, encoding: .utf8))

        for forbidden in ["processIdentifier", "pid", "icon", "focusRevision", "transcript", "processedDictation"] {
            #expect(!text.contains(forbidden))
        }
    }
}

private struct ApplicationStoreFixture {
    let suite: String
    let defaults: UserDefaults
    let key = "CadenceTests.applicationLibrary.owned-by-fixture"
    let store: ApplicationConfigurationStore

    init() throws {
        suite = "CadenceTests.ApplicationLibrary.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        store = ApplicationConfigurationStore(defaults: defaults, key: key)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }

    func configuration(
        id: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    ) throws -> ApplicationConfiguration {
        try ApplicationConfiguration(
            id: id,
            application: ApplicationReference(
                id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                lastKnownBundleURL: URL(fileURLWithPath: "/Applications/Slack.app"),
                lastKnownDisplayName: " Slack "
            ),
            isEnabled: true,
            familyID: .messaging,
            presetSelection: .explicit(try ScribePresetID("messaging.formal")),
            customGuidance: ScribeCustomGuidance("Use British spelling."),
            revision: 1
        )
    }
}
