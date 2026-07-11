import Foundation

struct ScribePresetCatalogState: Codable, Equatable, Sendable {
    let catalogRevision: Int
    let fallbackFamilyID: ScribeEnvironmentFamilyID
    let fallbackPresetID: ScribePresetID

    static let generalNeutral = ScribePresetCatalogState(
        catalogRevision: 1,
        fallbackFamilyID: .general,
        fallbackPresetID: try! ScribePresetID("general.neutral")
    )
}

struct ScribePresetCatalogStateEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let state: ScribePresetCatalogState

    init(
        schemaVersion: Int = ScribePresetCatalogStateEnvelope.currentSchemaVersion,
        state: ScribePresetCatalogState
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}

enum ScribePresetCatalogStateRejection: Equatable, Sendable {
    case malformed
    case futureSchema
    case unsupportedCatalogRevision
    case invalidState
}

enum ScribePresetCatalogStateLoadResult: Equatable, Sendable {
    case absent
    case valid(ScribePresetCatalogState)
    case rejected(ScribePresetCatalogStateRejection)
}

enum SettingsCategoryID: String, CaseIterable, Codable, Equatable, Sendable {
    case general
    case dictation
    case scribe
    case apps
    case providers
    case privacy
    case advanced
}

struct SettingsPresentationState: Codable, Equatable, Sendable {
    let selectedCategory: SettingsCategoryID
    let isAdvancedExpanded: Bool
}

struct SettingsPresentationEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let state: SettingsPresentationState

    init(
        schemaVersion: Int = SettingsPresentationEnvelope.currentSchemaVersion,
        state: SettingsPresentationState
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
    }
}

enum SettingsPresentationRejection: Equatable, Sendable {
    case malformed
    case futureSchema
}

enum SettingsPresentationLoadResult: Equatable, Sendable {
    case absent
    case valid(SettingsPresentationState)
    case rejected(SettingsPresentationRejection)
}
