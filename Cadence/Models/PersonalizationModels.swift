import Foundation

enum PersonalShortcutScope: Codable, Equatable, Sendable {
    case global
    case application(String)
}

struct PersonalShortcut: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var trigger: String
    var template: String
    var isEnabled: Bool
    var scope: PersonalShortcutScope

    init(
        id: UUID = UUID(),
        trigger: String,
        template: String,
        isEnabled: Bool = true,
        scope: PersonalShortcutScope = .global
    ) {
        self.id = id
        self.trigger = trigger
        self.template = template
        self.isEnabled = isEnabled
        self.scope = scope
    }

    var isValid: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum WritingTone: String, CaseIterable, Codable, Identifiable, Sendable {
    case natural
    case professional
    case casual
    case direct

    var id: String { rawValue }
}

enum WritingLength: String, CaseIterable, Codable, Identifiable, Sendable {
    case concise
    case balanced
    case detailed

    var id: String { rawValue }
}

enum WritingPunctuation: String, CaseIterable, Codable, Identifiable, Sendable {
    case natural
    case minimal
    case literal

    var id: String { rawValue }
}

enum WritingFormatting: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case plainText
    case structured

    var id: String { rawValue }
}

struct WritingStyleProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var appBundleIdentifier: String?
    var tone: WritingTone
    var length: WritingLength
    var punctuation: WritingPunctuation
    var formatting: WritingFormatting
    var preservesCodeLiterals: Bool
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        appBundleIdentifier: String? = nil,
        tone: WritingTone = .natural,
        length: WritingLength = .balanced,
        punctuation: WritingPunctuation = .natural,
        formatting: WritingFormatting = .automatic,
        preservesCodeLiterals: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.appBundleIdentifier = appBundleIdentifier
        self.tone = tone
        self.length = length
        self.punctuation = punctuation
        self.formatting = formatting
        self.preservesCodeLiterals = preservesCodeLiterals
        self.isEnabled = isEnabled
    }
}

struct PersonalizationLibrary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let empty = PersonalizationLibrary(shortcuts: [], styleProfiles: [])

    let schemaVersion: Int
    var shortcuts: [PersonalShortcut]
    var styleProfiles: [WritingStyleProfile]

    init(
        schemaVersion: Int = currentSchemaVersion,
        shortcuts: [PersonalShortcut],
        styleProfiles: [WritingStyleProfile]
    ) {
        self.schemaVersion = schemaVersion
        self.shortcuts = shortcuts
        self.styleProfiles = styleProfiles
    }
}
