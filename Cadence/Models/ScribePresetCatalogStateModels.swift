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
    case meetings
    case apps
    case providers
    case privacy
    case advanced

    static func visibleCategories(
        scribeEnabled: Bool,
        granolaEnabled: Bool
    ) -> [SettingsCategoryID] {
        var categories: [SettingsCategoryID] = [.general, .dictation]
        if scribeEnabled {
            categories.append(.scribe)
        }
        if granolaEnabled {
            categories.append(.meetings)
        }
        categories.append(contentsOf: [.privacy, .advanced])
        return categories
    }

    func normalized(
        scribeEnabled: Bool,
        granolaEnabled: Bool
    ) -> SettingsCategoryID {
        switch self {
        case .apps:
            if scribeEnabled {
                return .scribe
            }
            if granolaEnabled {
                return .meetings
            }
            return .general
        case .providers:
            return scribeEnabled ? .scribe : .general
        case .scribe where !scribeEnabled:
            return .general
        case .meetings where !granolaEnabled:
            return .general
        default:
            return self
        }
    }
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
