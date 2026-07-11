import Foundation

enum LegacySlackIdentityResolution: Equatable, Sendable {
    case unique(ApplicationReference)
    case missing(ApplicationReference)
    case ambiguous
}

struct ApplicationConfigurationMigrationService {
    private static let slackBundleIdentifier = "com.tinyspeck.slackmacgap"
    private static let slackBundleURL = URL(fileURLWithPath: "/Applications/Slack.app")

    private let destinationStore: ApplicationConfigurationStore
    private let markerStore: AdaptiveScribeMigrationMarkerStore
    private let makeConfigurationID: () -> UUID
    private let makeReferenceID: () -> UUID
    private let slackIdentityResolution: (() -> LegacySlackIdentityResolution)?
    private let interrupt: (AdaptiveScribeMigrationPoint) throws -> Void

    init(
        destinationStore: ApplicationConfigurationStore,
        markerStore: AdaptiveScribeMigrationMarkerStore,
        makeConfigurationID: @escaping () -> UUID = { UUID() },
        makeReferenceID: @escaping () -> UUID = { UUID() },
        slackIdentityResolution: (() -> LegacySlackIdentityResolution)? = nil,
        interrupt: @escaping (AdaptiveScribeMigrationPoint) throws -> Void = { _ in }
    ) {
        self.destinationStore = destinationStore
        self.markerStore = markerStore
        self.makeConfigurationID = makeConfigurationID
        self.makeReferenceID = makeReferenceID
        self.slackIdentityResolution = slackIdentityResolution
        self.interrupt = interrupt
    }

    func migrate(
        _ legacy: WritingEnvironmentPreferenceLoadResult
    ) throws -> AdaptiveScribeDomainMigrationResult {
        switch markerStore.load(.applicationConfigurations) {
        case .valid:
            guard case .valid = destinationStore.load() else {
                throw AdaptiveScribeMigrationError.destinationRejected
            }
            return .alreadyComplete
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        case .absent:
            break
        }
        guard case .rejected = legacy else {
            return try migrateDecodable(legacy)
        }
        throw AdaptiveScribeMigrationError.sourceRejected
    }

    private func migrateDecodable(
        _ legacy: WritingEnvironmentPreferenceLoadResult
    ) throws -> AdaptiveScribeDomainMigrationResult {
        let destination = destinationStore.load()
        let expected: ApplicationConfigurationLibrary
        switch destination {
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        case .absent:
            expected = try makeLibrary(from: legacy, existing: nil)
            try interrupt(.beforeDestinationWrite)
            try destinationStore.save(expected)
            try interrupt(.afterDestinationWrite)
        case let .valid(existing):
            expected = try makeLibrary(from: legacy, existing: existing)
            guard existing.semanticallyEquals(expected) else {
                throw AdaptiveScribeMigrationError.destinationConflict
            }
        }

        guard case let .valid(readback) = destinationStore.load(),
              readback.semanticallyEquals(expected) else {
            throw AdaptiveScribeMigrationError.semanticReadbackFailed
        }
        try interrupt(.afterSemanticReadback)

        try interrupt(.beforeMarkerWrite)
        try markerStore.markComplete(.applicationConfigurations)
        try interrupt(.afterMarkerWrite)
        return .migrated
    }

    private func makeLibrary(
        from legacy: WritingEnvironmentPreferenceLoadResult,
        existing: ApplicationConfigurationLibrary?
    ) throws -> ApplicationConfigurationLibrary {
        let preferences: [WritingEnvironmentPreference]
        switch legacy {
        case .absent:
            preferences = []
        case .rejected:
            throw AdaptiveScribeMigrationError.sourceRejected
        case let .valid(value):
            preferences = value
        }

        let slackPreferences = preferences.filter { $0.environmentID == .slack }
        guard slackPreferences.count <= 1 else {
            throw AdaptiveScribeMigrationError.unsupportedLegacyState
        }
        guard let slack = slackPreferences.first else {
            return ApplicationConfigurationLibrary(revision: 1, configurations: [])
        }
        guard slack.definitionVersion == 1,
              [.formal, .neutral, .casual].contains(slack.selectedBehaviorID) else {
            throw AdaptiveScribeMigrationError.unsupportedLegacyState
        }

        let existingSlack = existing?.configurations.count == 1
            ? existing?.configurations.first
            : nil
        let reference: ApplicationReference
        if let existingSlack {
            reference = existingSlack.application
        } else {
            let resolution = slackIdentityResolution?() ?? .missing(ApplicationReference(
                id: makeReferenceID(),
                bundleIdentifier: Self.slackBundleIdentifier,
                lastKnownBundleURL: Self.slackBundleURL,
                lastKnownDisplayName: "Slack"
            ))
            switch resolution {
            case let .unique(value), let .missing(value):
                guard value.normalized().bundleIdentifier == Self.slackBundleIdentifier else {
                    throw AdaptiveScribeMigrationError.unsupportedLegacyState
                }
                reference = value.normalized()
            case .ambiguous:
                throw AdaptiveScribeMigrationError.identitySelectionRequired
            }
        }
        let configuration = try ApplicationConfiguration(
            id: existingSlack?.id ?? makeConfigurationID(),
            application: reference,
            isEnabled: slack.isEnabled,
            familyID: .messaging,
            presetSelection: .explicit(try ScribePresetID("messaging.\(slack.selectedBehaviorID.rawValue)")),
            customGuidance: nil,
            revision: 1
        )
        return ApplicationConfigurationLibrary(revision: 1, configurations: [configuration])
    }
}
