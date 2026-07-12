import Foundation

enum AdaptiveScribeMigrationDomain: String, CaseIterable, Codable, Equatable, Sendable {
    case providerLibrary
    case applicationConfigurations
    case presetCatalogState
    case settingsPresentation
    case featureGates
}

struct AdaptiveScribeMigrationMarker: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentMigrationVersion = 1

    let schemaVersion: Int
    let migrationVersion: Int
    let domain: AdaptiveScribeMigrationDomain

    init(
        schemaVersion: Int = AdaptiveScribeMigrationMarker.currentSchemaVersion,
        migrationVersion: Int = AdaptiveScribeMigrationMarker.currentMigrationVersion,
        domain: AdaptiveScribeMigrationDomain
    ) {
        self.schemaVersion = schemaVersion
        self.migrationVersion = migrationVersion
        self.domain = domain
    }
}

enum AdaptiveScribeMigrationMarkerLoadResult: Equatable, Sendable {
    case absent
    case valid
    case rejected
}

final class AdaptiveScribeMigrationMarkerStore {
    static let defaultKeyPrefix = "Cadence.adaptiveScribeMigration.v2"

    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = AdaptiveScribeMigrationMarkerStore.defaultKeyPrefix
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(_ domain: AdaptiveScribeMigrationDomain) -> AdaptiveScribeMigrationMarkerLoadResult {
        guard let data = defaults.data(forKey: key(for: domain)) else { return .absent }
        guard let marker = try? JSONDecoder().decode(AdaptiveScribeMigrationMarker.self, from: data),
              marker.schemaVersion == AdaptiveScribeMigrationMarker.currentSchemaVersion,
              marker.migrationVersion == AdaptiveScribeMigrationMarker.currentMigrationVersion,
              marker.domain == domain else {
            return .rejected
        }
        return .valid
    }

    func markComplete(_ domain: AdaptiveScribeMigrationDomain) throws {
        let marker = AdaptiveScribeMigrationMarker(domain: domain)
        let markerKey = key(for: domain)
        let previous = defaults.data(forKey: markerKey)
        defaults.set(try JSONEncoder().encode(marker), forKey: markerKey)
        guard load(domain) == .valid else {
            if let previous { defaults.set(previous, forKey: markerKey) }
            else { defaults.removeObject(forKey: markerKey) }
            throw AdaptiveScribeMigrationError.semanticReadbackFailed
        }
    }

    func data(for domain: AdaptiveScribeMigrationDomain) -> Data? {
        defaults.data(forKey: key(for: domain))
    }

    private func key(for domain: AdaptiveScribeMigrationDomain) -> String {
        "\(keyPrefix).\(domain.rawValue)"
    }
}

enum AdaptiveScribeMigrationPoint: Equatable, Sendable {
    case beforeDestinationWrite
    case afterDestinationWrite
    case afterSemanticReadback
    case beforeMarkerWrite
    case afterMarkerWrite
}

enum AdaptiveScribeMigrationError: Error, Equatable, Sendable {
    case sourceRejected
    case destinationRejected
    case destinationConflict
    case unsupportedLegacyState
    case semanticReadbackFailed
    case identitySelectionRequired
}

enum AdaptiveScribeDomainMigrationResult: Equatable, Sendable {
    case migrated
    case alreadyComplete
}

struct ProviderLibraryMigrationService {
    private let destinationStore: ScribeProviderLibraryStore
    private let markerStore: AdaptiveScribeMigrationMarkerStore
    private let makeID: () -> UUID
    private let interrupt: (AdaptiveScribeMigrationPoint) throws -> Void

    init(
        destinationStore: ScribeProviderLibraryStore,
        markerStore: AdaptiveScribeMigrationMarkerStore,
        makeID: @escaping () -> UUID = { UUID() },
        interrupt: @escaping (AdaptiveScribeMigrationPoint) throws -> Void = { _ in }
    ) {
        self.destinationStore = destinationStore
        self.markerStore = markerStore
        self.makeID = makeID
        self.interrupt = interrupt
    }

    func migrate(
        _ legacy: ScribeProviderConfigurationLoadResult
    ) throws -> AdaptiveScribeDomainMigrationResult {
        switch markerStore.load(.providerLibrary) {
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
        _ legacy: ScribeProviderConfigurationLoadResult
    ) throws -> AdaptiveScribeDomainMigrationResult {
        let destination = destinationStore.load()
        let expected: ScribeProviderLibrary
        switch destination {
        case .rejected:
            throw AdaptiveScribeMigrationError.destinationRejected
        case .absent:
            expected = try makeLibrary(from: legacy, existingID: nil)
            try interrupt(.beforeDestinationWrite)
            try destinationStore.save(expected)
            try interrupt(.afterDestinationWrite)
        case let .valid(existing):
            let existingID = existing.configurations.count == 1
                ? existing.configurations[0].id
                : nil
            expected = try makeLibrary(from: legacy, existingID: existingID)
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
        try markerStore.markComplete(.providerLibrary)
        try interrupt(.afterMarkerWrite)
        return .migrated
    }

    private func makeLibrary(
        from legacy: ScribeProviderConfigurationLoadResult,
        existingID: UUID?
    ) throws -> ScribeProviderLibrary {
        switch legacy {
        case .absent:
            return ScribeProviderLibrary(revision: 1, configurations: [], activeConfigurationID: nil)
        case .rejected:
            throw AdaptiveScribeMigrationError.sourceRejected
        case let .valid(configuration):
            let id = existingID ?? makeID()
            let migrated = try ScribeProviderLibraryConfiguration(
                id: id,
                kind: configuration.kind,
                displayName: configuration.kind.displayName,
                normalizedOrigin: configuration.normalizedOrigin,
                baseURL: configuration.baseURL,
                requestURL: configuration.requestURL,
                selectedModelID: configuration.modelID,
                catalogID: configuration.catalogID,
                disclosureVersion: configuration.disclosureVersion,
                acceptedAt: configuration.acceptedAt,
                lastValidatedAt: configuration.acceptedAt,
                credentialReference: configuration.credentialReference,
                isEnabled: configuration.isEnabled
            )
            return ScribeProviderLibrary(
                revision: 1,
                configurations: [migrated],
                activeConfigurationID: configuration.isEnabled ? id : nil
            )
        }
    }
}
