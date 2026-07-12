import Foundation
import Testing
@testable import Cadence

struct ApplicationConfigurationTests {
    @Test
    func identityResolutionPrefersExactThenUniqueRebindAndFailsClosedForDuplicates() {
        let saved = ApplicationReference(
            bundleIdentifier: "example.app",
            lastKnownBundleURL: URL(fileURLWithPath: "/Applications/Old.app"),
            lastKnownDisplayName: "Old"
        )
        let exact = InstalledApplicationDescriptor(
            bundleURL: saved.lastKnownBundleURL, bundleIdentifier: "example.app",
            displayName: "Exact", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        let moved = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/New.app"), bundleIdentifier: "example.app",
            displayName: "Moved", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        #expect(ApplicationIdentityResolver.resolve(reference: saved, applications: [exact, moved], savedURLExists: true) == .exact(exact))
        #expect(ApplicationIdentityResolver.resolve(reference: saved, applications: [moved], savedURLExists: false) == .uniqueRebind(moved))
        let secondMoved = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Other.app"), bundleIdentifier: "example.app",
            displayName: "Other", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        #expect(ApplicationIdentityResolver.resolve(reference: saved, applications: [moved, secondMoved], savedURLExists: false) == .ambiguous)
        #expect(ApplicationIdentityResolver.resolve(reference: saved, applications: [], savedURLExists: false) == .missing)
        let invalid = ApplicationReference(
            bundleIdentifier: "example.app", lastKnownBundleURL: URL(fileURLWithPath: "/tmp/not-an-app"),
            lastKnownDisplayName: "Invalid"
        )
        #expect(ApplicationIdentityResolver.resolve(reference: invalid, applications: [exact], savedURLExists: false) == .invalid)
    }

    @Test
    func runtimeExactConfigurationRejectsDuplicateExactCopiesRatherThanChoosingByOrder() throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let first = try fixture.configuration()
        let duplicate = try ApplicationConfiguration(
            id: UUID(), application: ApplicationReference(
                id: UUID(), bundleIdentifier: first.application.bundleIdentifier,
                lastKnownBundleURL: first.application.lastKnownBundleURL,
                lastKnownDisplayName: first.application.lastKnownDisplayName
            ), isEnabled: true, familyID: .messaging, presetSelection: .familyDefault,
            customGuidance: nil, revision: 1
        )
        let identity = ActiveApplicationIdentity(
            bundleIdentifier: first.application.bundleIdentifier,
            bundleURL: first.application.lastKnownBundleURL,
            displayName: "Slack", processIdentifier: 10
        )
        #expect(ApplicationIdentityResolver.runtimeExactConfiguration(
            identity: identity,
            library: .init(revision: 1, configurations: [first, duplicate])
        ) == nil)
    }

    @Test
    func guardedRebindPreservesIDsAndFieldsAndRejectsStaleOrAmbiguousRaces() async throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.configuration()
        try fixture.store.save(.init(revision: 4, configurations: [original]))
        let moved = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Slack New.app"),
            bundleIdentifier: original.application.bundleIdentifier,
            displayName: "Slack New", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        let writer = ApplicationConfigurationWriter(store: fixture.store)
        let committed = try await writer.rebind(
            configurationID: original.id,
            expectedLibraryRevision: 4,
            expectedConfigurationRevision: original.revision,
            expectedReferenceID: original.application.id,
            expectedOldURL: original.application.lastKnownBundleURL,
            snapshot: .init(generation: 9, applications: [moved]),
            newestSnapshot: { .init(generation: 9, applications: [moved]) },
            savedURLExists: { false }
        )
        #expect(committed.application.id == original.application.id)
        #expect(committed.id == original.id)
        #expect(committed.application.lastKnownBundleURL == moved.bundleURL)
        #expect(committed.presetSelection == original.presetSelection)
        #expect(committed.revision == original.revision + 1)
        guard case let .valid(library) = fixture.store.load() else { Issue.record("Expected rebound library"); return }
        #expect(library.revision == 5)

        let next = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Slack Latest.app"),
            bundleIdentifier: original.application.bundleIdentifier,
            displayName: "Slack Latest", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        await #expect(throws: ApplicationConfigurationWriterError.staleSnapshot) {
            _ = try await writer.rebind(
                configurationID: original.id,
                expectedLibraryRevision: 5,
                expectedConfigurationRevision: committed.revision,
                expectedReferenceID: original.application.id,
                expectedOldURL: committed.application.lastKnownBundleURL,
                snapshot: .init(generation: 9, applications: [next]),
                newestSnapshot: { .init(generation: 10, applications: [next]) },
                savedURLExists: { false }
            )
        }
    }

    @Test
    func rebindRollsBackExactBytesWhenCatalogChangesAfterSave() async throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.configuration()
        try fixture.store.save(.init(revision: 4, configurations: [original]))
        let originalBytes = fixture.store.rawRepresentation()
        let moved = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Slack New.app"),
            bundleIdentifier: original.application.bundleIdentifier,
            displayName: "Slack New", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        let snapshots = RebindSnapshotSequence([
            .init(generation: 9, applications: [moved]),
            .init(generation: 10, applications: [])
        ])
        let writer = ApplicationConfigurationWriter(store: fixture.store)

        await #expect(throws: ApplicationConfigurationWriterError.staleSnapshot) {
            _ = try await writer.rebind(
                configurationID: original.id,
                expectedLibraryRevision: 4,
                expectedConfigurationRevision: original.revision,
                expectedReferenceID: original.application.id,
                expectedOldURL: original.application.lastKnownBundleURL,
                snapshot: .init(generation: 9, applications: [moved]),
                newestSnapshot: { await snapshots.next() },
                savedURLExists: { false }
            )
        }
        #expect(fixture.store.rawRepresentation() == originalBytes)
        #expect(fixture.store.load() == .valid(.init(revision: 4, configurations: [original]).normalized()))
    }

    @Test
    func rebindRollsBackExactBytesWhenCandidateIdentityChangesAfterSave() async throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.configuration()
        try fixture.store.save(.init(revision: 4, configurations: [original]))
        let originalBytes = fixture.store.rawRepresentation()
        let moved = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Slack New.app"),
            bundleIdentifier: original.application.bundleIdentifier,
            displayName: "Slack New", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        let replacement = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Slack Replacement.app"),
            bundleIdentifier: original.application.bundleIdentifier,
            displayName: "Slack Replacement", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        let snapshots = RebindSnapshotSequence([
            .init(generation: 9, applications: [moved]),
            .init(generation: 9, applications: [replacement])
        ])
        let writer = ApplicationConfigurationWriter(store: fixture.store)

        await #expect(throws: ApplicationConfigurationWriterError.staleSnapshot) {
            _ = try await writer.rebind(
                configurationID: original.id,
                expectedLibraryRevision: 4,
                expectedConfigurationRevision: original.revision,
                expectedReferenceID: original.application.id,
                expectedOldURL: original.application.lastKnownBundleURL,
                snapshot: .init(generation: 9, applications: [moved]),
                newestSnapshot: { await snapshots.next() },
                savedURLExists: { false }
            )
        }
        #expect(fixture.store.rawRepresentation() == originalBytes)
    }

    @Test
    func staleRebindRollbackUsesCASAndPreservesSameWriterMutationDuringPostSaveAwait() async throws {
        let fixture = try ApplicationStoreFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.configuration()
        try fixture.store.save(.init(revision: 4, configurations: [original]))
        let moved = InstalledApplicationDescriptor(
            bundleURL: URL(fileURLWithPath: "/Applications/Slack New.app"),
            bundleIdentifier: original.application.bundleIdentifier,
            displayName: "Slack New", version: nil, build: nil, isInstalled: true, isRunning: false
        )
        let gate = RebindPostSaveSnapshotGate(
            stable: .init(generation: 9, applications: [moved]),
            stale: .init(generation: 10, applications: [])
        )
        let writer = ApplicationConfigurationWriter(store: fixture.store)
        let rebind = Task {
            try await writer.rebind(
                configurationID: original.id,
                expectedLibraryRevision: 4,
                expectedConfigurationRevision: original.revision,
                expectedReferenceID: original.application.id,
                expectedOldURL: original.application.lastKnownBundleURL,
                snapshot: .init(generation: 9, applications: [moved]),
                newestSnapshot: { await gate.next() },
                savedURLExists: { false }
            )
        }
        await gate.waitUntilPostSaveCheck()
        let updated = try await writer.updateCustomGuidance(
            configurationID: original.id,
            input: "Keep the concurrent edit."
        )
        await gate.releasePostSaveCheck()

        await #expect(throws: ApplicationConfigurationWriterError.concurrentMutation) {
            _ = try await rebind.value
        }
        guard case let .valid(library) = fixture.store.load() else {
            Issue.record("Expected concurrent mutation to remain valid")
            return
        }
        #expect(library.configurations.first?.customGuidance == updated.customGuidance)
        #expect(library.configurations.first?.revision == updated.revision)
        #expect(library.revision == 6)
    }
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

private actor RebindSnapshotSequence {
    private var snapshots: [InstalledApplicationCatalogSnapshot]
    init(_ snapshots: [InstalledApplicationCatalogSnapshot]) { self.snapshots = snapshots }
    func next() -> InstalledApplicationCatalogSnapshot { snapshots.removeFirst() }
}

private actor RebindPostSaveSnapshotGate {
    private let stable: InstalledApplicationCatalogSnapshot
    private let stale: InstalledApplicationCatalogSnapshot
    private var callCount = 0
    private var postSaveCheckStarted = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(stable: InstalledApplicationCatalogSnapshot, stale: InstalledApplicationCatalogSnapshot) {
        self.stable = stable
        self.stale = stale
    }
    func next() async -> InstalledApplicationCatalogSnapshot {
        callCount += 1
        guard callCount > 1 else { return stable }
        postSaveCheckStarted = true
        await withCheckedContinuation { continuation = $0 }
        return stale
    }
    func waitUntilPostSaveCheck() async {
        while !postSaveCheckStarted { await Task.yield() }
    }
    func releasePostSaveCheck() {
        continuation?.resume()
        continuation = nil
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
