import Foundation
import Testing
@testable import Cadence

struct ApplicationConfigurationMigrationTests {
    @Test(arguments: [
        AdaptiveScribeMigrationPoint.beforeDestinationWrite,
        .afterDestinationWrite,
        .afterSemanticReadback,
        .beforeMarkerWrite
    ])
    func applicationMigrationResumesAtEveryMarkerLastBoundary(
        point: AdaptiveScribeMigrationPoint
    ) throws {
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        let preferences = [WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .neutral,
            definitionVersion: 1
        )]
        var stopped = false
        #expect(throws: ApplicationMigrationInterruption.self) {
            try fixture.migration(interrupt: { observed in
                guard observed == point, !stopped else { return }
                stopped = true
                throw ApplicationMigrationInterruption()
            }).migrate(.valid(preferences))
        }
        #expect(fixture.markerStore.load(.applicationConfigurations) == .absent)
        _ = try fixture.migration().migrate(.valid(preferences))
        guard case let .valid(library) = fixture.applicationStore.load() else {
            Issue.record("Expected resumed app library")
            return
        }
        #expect(library.configurations.count == 1)
    }

    @Test
    func injectedSlackIdentityHandlesUniqueMissingAndAmbiguousWithoutScanning() throws {
        let reference = ApplicationReference(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            lastKnownBundleURL: URL(fileURLWithPath: "/Volumes/Work/Slack.app"),
            lastKnownDisplayName: "Slack"
        )
        let preferences = [WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .formal,
            definitionVersion: 1
        )]

        for outcome in [
            LegacySlackIdentityResolution.unique(reference),
            .missing(reference)
        ] {
            let fixture = try ApplicationMigrationFixture(identityResolution: outcome)
            defer { fixture.cleanUp() }
            _ = try fixture.migration().migrate(.valid(preferences))
            guard case let .valid(library) = fixture.applicationStore.load() else {
                Issue.record("Expected migrated Slack")
                continue
            }
            #expect(library.configurations.first?.application == reference)
        }

        let ambiguous = try ApplicationMigrationFixture(identityResolution: .ambiguous)
        defer { ambiguous.cleanUp() }
        #expect(throws: AdaptiveScribeMigrationError.identitySelectionRequired) {
            try ambiguous.migration().migrate(.valid(preferences))
        }
        #expect(ambiguous.applicationStore.load() == .absent)
        #expect(ambiguous.markerStore.load(.applicationConfigurations) == .absent)
    }

    @Test
    func completedApplicationMarkerAllowsValidV2EditsAndRejectsCorruption() throws {
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        let preferences = [WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .formal,
            definitionVersion: 1
        )]
        _ = try fixture.migration().migrate(.valid(preferences))
        guard case let .valid(library) = fixture.applicationStore.load(),
              let original = library.configurations.first else {
            Issue.record("Expected migrated app")
            return
        }
        let edited = try ApplicationConfiguration(
            id: original.id,
            application: original.application,
            isEnabled: original.isEnabled,
            familyID: original.familyID,
            presetSelection: .explicit(try ScribePresetID("messaging.casual")),
            customGuidance: try ScribeCustomGuidance("Keep replies short."),
            revision: original.revision + 1
        )
        try fixture.applicationStore.save(.init(revision: 2, configurations: [edited]))

        #expect(try fixture.migration().migrate(.rejected(.malformed)) == .alreadyComplete)
        guard case let .valid(reloaded) = fixture.applicationStore.load() else {
            Issue.record("Expected edited app")
            return
        }
        #expect(reloaded.configurations.first?.customGuidance?.rawValue == "Keep replies short.")

        let corrupt = Data("corrupt".utf8)
        fixture.defaults.set(corrupt, forKey: fixture.applicationKey)
        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.valid(preferences))
        }
        #expect(fixture.defaults.data(forKey: fixture.applicationKey) == corrupt)
    }

    @Test
    func malformedLegacyAndFutureApplicationDestinationRemainByteExactAndUnmarked() throws {
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        let malformed = Data("malformed-legacy-apps".utf8)
        fixture.defaults.set(malformed, forKey: fixture.legacyKey)
        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.rejected(.malformed))
        }
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == malformed)
        #expect(fixture.markerStore.load(.applicationConfigurations) == .absent)

        let future = try JSONEncoder().encode(ApplicationConfigurationEnvelope(
            schemaVersion: 999,
            library: .init(revision: 1, configurations: [])
        ))
        fixture.defaults.set(future, forKey: fixture.applicationKey)
        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.absent)
        }
        #expect(fixture.defaults.data(forKey: fixture.applicationKey) == future)
        #expect(fixture.markerStore.load(.applicationConfigurations) == .absent)
    }
    @Test(arguments: [
        (WritingBehaviorID.formal, "messaging.formal", true),
        (.neutral, "messaging.neutral", true),
        (.casual, "messaging.casual", true),
        (.formal, "messaging.formal", false)
    ])
    func exactSlackStatesMapWithoutMappingClaude(
        behavior: WritingBehaviorID,
        presetID: String,
        enabled: Bool
    ) throws {
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        let preferences = [
            WritingEnvironmentPreference(
                environmentID: .slack,
                isEnabled: enabled,
                selectedBehaviorID: behavior,
                definitionVersion: 1
            ),
            WritingEnvironmentPreference(
                environmentID: .claudeCode,
                isEnabled: true,
                selectedBehaviorID: .precise,
                definitionVersion: 1
            )
        ]
        try fixture.legacyStore.save(preferences)
        let sourceBytes = try #require(fixture.defaults.data(forKey: fixture.legacyKey))

        _ = try fixture.migration().migrate(.valid(preferences))

        guard case let .valid(library) = fixture.applicationStore.load(),
              let slack = library.configurations.first else {
            Issue.record("Expected migrated Slack configuration")
            return
        }
        #expect(library.configurations.count == 1)
        #expect(slack.application.bundleIdentifier == "com.tinyspeck.slackmacgap")
        #expect(slack.familyID == .messaging)
        #expect(slack.presetSelection == .explicit(try ScribePresetID(presetID)))
        #expect(slack.isEnabled == enabled)
        #expect(!library.configurations.contains { $0.application.bundleIdentifier.contains("claude") })
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == sourceBytes)
    }

    @Test
    func interruptedApplicationMigrationResumesWithoutDuplicatesOrSourceMutation() throws {
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        let preferences = [WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .neutral,
            definitionVersion: 1
        )]
        try fixture.legacyStore.save(preferences)
        let sourceBytes = try #require(fixture.defaults.data(forKey: fixture.legacyKey))
        var stopped = false

        #expect(throws: ApplicationMigrationInterruption.self) {
            try fixture.migration(interrupt: { point in
                guard point == .beforeMarkerWrite, !stopped else { return }
                stopped = true
                throw ApplicationMigrationInterruption()
            }).migrate(.valid(preferences))
        }
        #expect(fixture.markerStore.load(.applicationConfigurations) == .absent)
        _ = try fixture.migration().migrate(.valid(preferences))
        _ = try fixture.migration().migrate(.valid(preferences))

        guard case let .valid(library) = fixture.applicationStore.load() else {
            Issue.record("Expected migrated app library")
            return
        }
        #expect(library.configurations.count == 1)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == sourceBytes)
    }

    @Test
    func invalidOrAmbiguousLegacySlackFailsClosedAndLeavesDestinationUnmarked() throws {
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        let duplicate = WritingEnvironmentPreference(
            environmentID: .slack,
            isEnabled: true,
            selectedBehaviorID: .neutral,
            definitionVersion: 1
        )

        #expect(throws: AdaptiveScribeMigrationError.self) {
            try fixture.migration().migrate(.valid([duplicate, duplicate]))
        }
        #expect(fixture.applicationStore.load() == .absent)
        #expect(fixture.markerStore.load(.applicationConfigurations) == .absent)
    }

    @Test
    func retainedLegacyApplicationGoldenBytesRemainDecodableWithoutCreatingCodex() throws {
        let data = try Data(contentsOf: applicationMigrationFixture("legacy-application-preferences.json"))
        let fixture = try ApplicationMigrationFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(data, forKey: fixture.legacyKey)
        let source = fixture.legacyStore.load()
        _ = try fixture.migration().migrate(source)
        let legacy = try JSONDecoder().decode(WritingEnvironmentPreferenceLibrary.self, from: data)

        #expect(legacy.preferences.contains { $0.environmentID == .slack })
        #expect(legacy.preferences.contains { $0.environmentID == .claudeCode })
        #expect(!legacy.preferences.contains { $0.environmentID.rawValue.contains("codex") })
        #expect(fixture.legacyStore.load() == source)
        #expect(fixture.defaults.data(forKey: fixture.legacyKey) == data)
    }
}

private struct ApplicationMigrationInterruption: Error {}

private func applicationMigrationFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/AdaptiveScribe")
        .appendingPathComponent(name)
}

private struct ApplicationMigrationFixture {
    let suite: String
    let defaults: UserDefaults
    let legacyKey = "legacy-environments"
    let applicationKey = "application-v1"
    let markerPrefix = "markers"
    let legacyStore: WritingEnvironmentStore
    let applicationStore: ApplicationConfigurationStore
    let markerStore: AdaptiveScribeMigrationMarkerStore
    let identityResolution: LegacySlackIdentityResolution

    init(identityResolution: LegacySlackIdentityResolution? = nil) throws {
        suite = "CadenceTests.ApplicationMigration.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        legacyStore = WritingEnvironmentStore(defaults: defaults, key: legacyKey)
        applicationStore = ApplicationConfigurationStore(defaults: defaults, key: applicationKey)
        markerStore = AdaptiveScribeMigrationMarkerStore(defaults: defaults, keyPrefix: markerPrefix)
        self.identityResolution = identityResolution ?? .missing(ApplicationReference(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            lastKnownBundleURL: URL(fileURLWithPath: "/Applications/Slack.app"),
            lastKnownDisplayName: "Slack"
        ))
    }

    func migration(
        interrupt: @escaping (AdaptiveScribeMigrationPoint) throws -> Void = { _ in }
    ) -> ApplicationConfigurationMigrationService {
        ApplicationConfigurationMigrationService(
            destinationStore: applicationStore,
            markerStore: markerStore,
            makeConfigurationID: { UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")! },
            makeReferenceID: { UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")! },
            slackIdentityResolution: { self.identityResolution },
            interrupt: interrupt
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}
