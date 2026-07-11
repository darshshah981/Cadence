import Foundation

enum ScribeEnvironmentFamilyID: String, CaseIterable, Codable, Equatable, Sendable {
    case general
    case messaging
    case coding
}

struct ScribePresetID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(_ input: String) throws {
        let normalized = input.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 128,
              !normalized.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw ApplicationConfigurationValidationError.invalidPreset
        }
        rawValue = normalized
    }

    init?(rawValue: String) {
        guard let value = try? ScribePresetID(rawValue) else { return nil }
        self = value
    }
}

enum ScribePresetSelection: Codable, Equatable, Sendable {
    case familyDefault
    case explicit(ScribePresetID)
}

struct ScribeCustomGuidance: RawRepresentable, Codable, Equatable, Sendable {
    static let maximumUTF8Bytes = 2_000

    let rawValue: String

    init(_ input: String) throws {
        let normalized = input.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.utf8.count <= Self.maximumUTF8Bytes else {
            throw ApplicationConfigurationValidationError.guidanceTooLarge
        }
        let invalidControl = normalized.unicodeScalars.contains {
            ($0.value < 0x20 && $0.value != 0x0A && $0.value != 0x0D && $0.value != 0x09)
                || $0.value == 0x7F
        }
        guard !invalidControl else {
            throw ApplicationConfigurationValidationError.invalidGuidance
        }
        rawValue = normalized
    }

    init?(rawValue: String) {
        guard let value = try? ScribeCustomGuidance(rawValue) else { return nil }
        self = value
    }
}

enum ApplicationConfigurationValidationError: Error, Equatable, Sendable {
    case invalidReference
    case invalidPreset
    case incompatiblePreset
    case invalidGuidance
    case guidanceTooLarge
    case invalidRevision
}

struct ApplicationConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let application: ApplicationReference
    let isEnabled: Bool
    let familyID: ScribeEnvironmentFamilyID
    let presetSelection: ScribePresetSelection
    let customGuidance: ScribeCustomGuidance?
    let revision: Int

    init(
        id: UUID = UUID(),
        application: ApplicationReference,
        isEnabled: Bool,
        familyID: ScribeEnvironmentFamilyID,
        presetSelection: ScribePresetSelection,
        customGuidance: ScribeCustomGuidance?,
        revision: Int
    ) throws {
        self.id = id
        self.application = application
        self.isEnabled = isEnabled
        self.familyID = familyID
        self.presetSelection = presetSelection
        self.customGuidance = customGuidance?.rawValue.isEmpty == true ? nil : customGuidance
        self.revision = revision
    }

    func normalized() -> ApplicationConfiguration {
        try! ApplicationConfiguration(
            id: id,
            application: application.normalized(),
            isEnabled: isEnabled,
            familyID: familyID,
            presetSelection: presetSelection,
            customGuidance: customGuidance,
            revision: revision
        )
    }
}

struct ApplicationConfigurationLibrary: Codable, Equatable, Sendable {
    let revision: Int
    let configurations: [ApplicationConfiguration]

    func normalized() -> ApplicationConfigurationLibrary {
        ApplicationConfigurationLibrary(
            revision: revision,
            configurations: configurations
                .map { $0.normalized() }
                .sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    func semanticallyEquals(_ other: ApplicationConfigurationLibrary) -> Bool {
        normalized() == other.normalized()
    }
}

struct ApplicationConfigurationEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let library: ApplicationConfigurationLibrary

    init(
        schemaVersion: Int = ApplicationConfigurationEnvelope.currentSchemaVersion,
        library: ApplicationConfigurationLibrary
    ) {
        self.schemaVersion = schemaVersion
        self.library = library
    }
}

enum ApplicationConfigurationRejection: Equatable, Sendable {
    case malformed
    case futureSchema
    case duplicateConfigurationID
    case duplicateApplicationReference
    case invalidConfiguration
}

enum ApplicationConfigurationLoadResult: Equatable, Sendable {
    case absent
    case valid(ApplicationConfigurationLibrary)
    case rejected(ApplicationConfigurationRejection)
}

enum SafeScribeGuidanceResolution: Equatable, Sendable {
    case generalNeutral
}

struct ResolvedScribeGuidance: Equatable, Sendable {
    let familyID: ScribeEnvironmentFamilyID
    let familyDefinitionVersion: Int
    let presetID: ScribePresetID
    let presetDefinitionVersion: Int
    let compiledPresetInstructions: String
    let customGuidance: ScribeCustomGuidance?
    let resolutionSource: ScribeGuidanceResolutionSource
    let preservesExactLiterals: Bool
}

enum ScribeGuidanceResolutionSource: Equatable, Sendable {
    case bundledDefault
    case configuredApplication
    case adaptationDisabledFallback
    case missingApplicationFallback
    case ambiguousApplicationFallback
    case invalidConfigurationFallback
}
