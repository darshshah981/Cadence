import Foundation

enum WritingEnvironmentID: String, CaseIterable, Codable, Identifiable, Sendable {
    case slack
    case claudeCode = "claude-code"
    case global

    var id: String { rawValue }
}

enum WritingBehaviorID: String, CaseIterable, Codable, Identifiable, Sendable {
    case formal
    case neutral
    case casual
    case precise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .neutral: return "Neutral"
        case .casual: return "Casual"
        case .precise: return "Precise"
        }
    }
}

struct WritingEnvironmentDefinition: Equatable, Sendable {
    let id: WritingEnvironmentID
    let displayName: String
    let definitionVersion: Int
    let defaultBehaviorID: WritingBehaviorID
    let supportedBehaviorIDs: [WritingBehaviorID]
    let behaviorInstructions: [WritingBehaviorID: String]

    func instructions(for behaviorID: WritingBehaviorID) -> String? {
        behaviorInstructions[behaviorID]
    }
}

struct WritingEnvironmentPreference: Codable, Equatable, Sendable {
    let environmentID: WritingEnvironmentID
    let isEnabled: Bool
    let selectedBehaviorID: WritingBehaviorID
    let definitionVersion: Int
}

struct WritingEnvironmentPreferenceLibrary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let preferences: [WritingEnvironmentPreference]

    init(
        schemaVersion: Int = WritingEnvironmentPreferenceLibrary.currentSchemaVersion,
        preferences: [WritingEnvironmentPreference]
    ) {
        self.schemaVersion = schemaVersion
        self.preferences = preferences
    }
}

enum WritingEnvironmentPreferenceRejection: Equatable, Sendable {
    case malformed
    case futureSchema
}

enum WritingEnvironmentPreferenceLoadResult: Equatable, Sendable {
    case absent
    case valid([WritingEnvironmentPreference])
    case rejected(WritingEnvironmentPreferenceRejection)
}

enum WritingEnvironmentResolutionSource: Equatable, Sendable {
    case bundledDefault
    case rememberedPreference
    case adaptationDisabledFallback
    case environmentDisabledFallback
    case unknownEnvironmentFallback
    case invalidPreferenceFallback
}

struct ResolvedWritingEnvironment: Equatable, Sendable {
    let environmentID: WritingEnvironmentID
    let environmentDisplayName: String
    let behaviorID: WritingBehaviorID
    let behaviorDisplayName: String
    let definitionVersion: Int
    let compiledInstructions: String
    let resolutionSource: WritingEnvironmentResolutionSource

    var cue: String {
        "\(environmentDisplayName) · \(behaviorDisplayName)"
    }
}

struct TargetRecognitionSignature: Codable, Equatable, Sendable {
    let role: String?
    let subrole: String?
    let identifierAncestry: [String]

    init(role: String?, subrole: String?, identifierAncestry: [String]) {
        self.role = role
        self.subrole = subrole
        self.identifierAncestry = identifierAncestry
    }
}
