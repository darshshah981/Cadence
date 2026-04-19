import AppKit
import Carbon
import Foundation

enum DictationSessionState: Equatable {
    case idle
    case listening
    case finalizing
    case inserting
    case error(String)
}

enum DictationTriggerMode: String, CaseIterable, Identifiable, Sendable {
    case holdToTalk
    case tapToStartStop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk:
            return "Hold To Talk"
        case .tapToStartStop:
            return "Press To Start/Stop"
        }
    }

    var shortDescription: String {
        switch self {
        case .holdToTalk:
            return "Press and hold to record, release to finish."
        case .tapToStartStop:
            return "Press once to start, then stop with the shortcut or the pill."
        }
    }
}

struct AudioChunk: Sendable {
    let samples: [Float]
    let frameCount: Int
    let sampleRate: Double
}

enum WhisperModelOption: String, CaseIterable, Identifiable, Sendable {
    case tinyEnglish
    case baseEnglish
    case smallEnglish
    case mediumEnglish

    var id: String { rawValue }

    var fileName: String {
        switch self {
        case .tinyEnglish:
            return "ggml-tiny.en.bin"
        case .baseEnglish:
            return "ggml-base.en.bin"
        case .smallEnglish:
            return "ggml-small.en.bin"
        case .mediumEnglish:
            return "ggml-medium.en.bin"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    var coreMLEncoderFileName: String {
        fileName.replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc")
    }

    var coreMLEncoderArchiveURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(coreMLEncoderFileName).zip")!
    }

    var displayName: String {
        switch self {
        case .tinyEnglish:
            return "Tiny English"
        case .baseEnglish:
            return "Base English"
        case .smallEnglish:
            return "Small English"
        case .mediumEnglish:
            return "Medium English"
        }
    }

    var shortLabel: String {
        switch self {
        case .tinyEnglish:
            return "tiny.en"
        case .baseEnglish:
            return "base.en"
        case .smallEnglish:
            return "small.en"
        case .mediumEnglish:
            return "medium.en"
        }
    }

    var approximateSize: String {
        switch self {
        case .tinyEnglish:
            return "~75 MB"
        case .baseEnglish:
            return "~140 MB"
        case .smallEnglish:
            return "~460 MB"
        case .mediumEnglish:
            return "~1.5 GB"
        }
    }

    var qualityDescriptor: String {
        switch self {
        case .tinyEnglish:
            return "Fastest"
        case .baseEnglish:
            return "Balanced"
        case .smallEnglish:
            return "Precise"
        case .mediumEnglish:
            return "High"
        }
    }
}

enum WhisperDecodingMode: String, CaseIterable, Identifiable, Sendable {
    case greedy
    case beamSearch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .greedy:
            return "Greedy"
        case .beamSearch:
            return "Beam Search"
        }
    }

    var shortLabel: String {
        switch self {
        case .greedy:
            return "greedy"
        case .beamSearch:
            return "beam"
        }
    }

    var productLabel: String {
        switch self {
        case .greedy:
            return "Fast"
        case .beamSearch:
            return "Accurate"
        }
    }
}

enum FillerWordPolicy: String, CaseIterable, Identifiable, Sendable {
    case preserve
    case remove

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preserve:
            return "Literal"
        case .remove:
            return "Cleaned"
        }
    }

    var description: String {
        switch self {
        case .preserve:
            return "Keep filler words like um, uh, and like."
        case .remove:
            return "Strip common filler words after transcription."
        }
    }
}

struct TranscriptionConfiguration: Equatable, Sendable {
    var model: WhisperModelOption = .baseEnglish
    var decodingMode: WhisperDecodingMode = .greedy
    var fillerWordPolicy: FillerWordPolicy = .preserve
    var keepContext: Bool = true
    var trimSilence: Bool = true
    var normalizeAudio: Bool = true
    var livePreviewEnabled: Bool = true
    var tapStopsOnNextKeyPress: Bool = false
    var vocabularyText: String = ""

    var summary: String {
        "\(model.shortLabel) • \(decodingMode.shortLabel) • " +
        fillerWordPolicy.rawValue + " • " +
        (keepContext ? "context" : "isolated") + " • " +
        (trimSilence ? "trim" : "raw") + " • " +
        (normalizeAudio ? "normalize" : "natural")
    }
}

struct AudioCaptureSessionMetrics: Sendable {
    let duration: TimeInterval
    let frameCount: Int
    let sampleRate: Double
    let speechDetected: Bool
    let speechFrameCount: Int
}

struct FinalTranscript: Sendable, Equatable {
    let rawText: String
    let cleanedText: String
    let duration: TimeInterval
}

struct PreviewTranscript: Sendable, Equatable {
    let confirmedText: String
    let unconfirmedText: String

    var composedText: String {
        [confirmedText, unconfirmedText]
            .filter { !$0.isEmpty }
            .joined(separator: confirmedText.isEmpty || unconfirmedText.isEmpty ? "" : " ")
    }
}

struct TranscriptHistoryItem: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = .now) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

struct VocabularyEntry: Equatable, Sendable {
    let canonical: String
    let aliases: [String]

    static func parseList(from text: String) -> [VocabularyEntry] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { return nil }

                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                guard let canonical = parts.first, !canonical.isEmpty else {
                    return nil
                }

                let aliases = parts.count > 1
                    ? parts[1]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    : []

                return VocabularyEntry(canonical: canonical, aliases: aliases)
            }
    }

    static func promptHint(from text: String) -> String {
        parseList(from: text)
            .flatMap { [$0.canonical] + $0.aliases }
            .joined(separator: ", ")
    }
}

struct VocabularyPostProcessor {
    static func apply(to text: String, configuration: TranscriptionConfiguration) -> String {
        let withoutFillers = applyFillerWordPolicy(to: text, policy: configuration.fillerWordPolicy)
        let entries = VocabularyEntry.parseList(from: configuration.vocabularyText)
        guard !entries.isEmpty else { return withoutFillers }

        let replacements = entries
            .flatMap { entry in
                ([entry.canonical] + entry.aliases).map { alias in
                    (alias, entry.canonical)
                }
            }
            .sorted { $0.0.count > $1.0.count }

        return replacements.reduce(withoutFillers) { partial, replacement in
            replaceOccurrences(of: replacement.0, with: replacement.1, in: partial)
        }
    }

    private static func applyFillerWordPolicy(to text: String, policy: FillerWordPolicy) -> String {
        guard policy == .remove else { return text }

        let fillers = [
            "um",
            "uh",
            "erm",
            "ah",
            "like",
            "you know",
            "i mean"
        ]

        let pattern = "(?i)(?<![[:alnum:]])\\s*,?\\s*(?:\(fillers.map(NSRegularExpression.escapedPattern).joined(separator: "|")))\\s*,?\\s*(?![[:alnum:]])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let stripped = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )

        return stripped
            .replacingOccurrences(of: "(^|\\s)[,]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: ",\\s*([,.!?;:])", with: "$1", options: .regularExpression)
            .replacingOccurrences(
                of: ",\\s+(?=(?:a|an|the|this|that|these|those|i|you|we|they|he|she|it)\\b)",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: ",\\s*,+", with: ", ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceOccurrences(of source: String, with target: String, in text: String) -> String {
        guard !source.isEmpty else { return text }
        let pattern = "(?i)(?<![[:alnum:]])" + NSRegularExpression.escapedPattern(for: source) + "(?![[:alnum:]])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: target
        )
    }
}

enum HUDVisualState: Equatable {
    case recording(triggerMode: DictationTriggerMode, showsHint: Bool)
    case transcribing
    case error(message: String)
}

struct HUDState: Equatable {
    let visualState: HUDVisualState
    let subtitle: String
    let level: Double
    let waveformLevels: [Double]
    let isVisible: Bool
    let showsSubtitle: Bool

    var showsControls: Bool {
        if case .recording(let triggerMode, _) = visualState {
            return triggerMode == .tapToStartStop
        }
        return false
    }

    static let idle = HUDState(
        visualState: .transcribing,
        subtitle: "",
        level: 0,
        waveformLevels: Array(repeating: 0, count: 16),
        isVisible: false,
        showsSubtitle: false
    )
}

enum HotkeyAction: String, CaseIterable, Identifiable, Sendable {
    case holdToTalk
    case tapToStartStop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk:
            return "Hold To Talk"
        case .tapToStartStop:
            return "Press To Start/Stop"
        }
    }

    var shortDescription: String {
        switch self {
        case .holdToTalk:
            return "Press and hold to record, release to finish. Limit this to 1-2 keys total."
        case .tapToStartStop:
            return "Press once to start, then stop from the shortcut or the pill. Use 3 or more keys total."
        }
    }

    var triggerMode: DictationTriggerMode {
        switch self {
        case .holdToTalk:
            return .holdToTalk
        case .tapToStartStop:
            return .tapToStartStop
        }
    }

    func supports(_ shortcut: HotkeyConfiguration) -> Bool {
        switch self {
        case .holdToTalk:
            return shortcut.componentCount <= 2
        case .tapToStartStop:
            return shortcut.componentCount >= 3
        }
    }

    var shortcutRuleDescription: String {
        switch self {
        case .holdToTalk:
            return "Use at most 2 keys total."
        case .tapToStartStop:
            return "Use at least 3 keys total."
        }
    }
}

struct HotkeyConfiguration: Equatable, Sendable {
    static let modifierOnlyKeyCode = UInt32.max

    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyDisplay: String

    var displayName: String {
        let modifiers = Self.modifierDisplayName(for: carbonModifiers)
        guard !isModifierOnly else {
            return modifiers.isEmpty ? "Shortcut" : modifiers
        }
        return modifiers.isEmpty ? keyDisplay : "\(modifiers) + \(keyDisplay)"
    }

    var symbolDisplayName: String {
        let parts = symbolParts
        return parts.isEmpty ? "Shortcut" : parts.joined(separator: " ")
    }

    var symbolParts: [String] {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if !isModifierOnly && !keyDisplay.isEmpty { parts.append(Self.symbolKeyName(for: keyDisplay)) }
        return parts
    }

    var isEmpty: Bool {
        keyDisplay.isEmpty && carbonModifiers == 0
    }

    var isModifierOnly: Bool {
        keyCode == Self.modifierOnlyKeyCode
    }

    var componentCount: Int {
        carbonModifiers.nonzeroBitCount + (isModifierOnly ? 0 : 1)
    }

    func conflicts(with other: HotkeyConfiguration) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }

    static let defaultHoldToTalk = HotkeyConfiguration(
        keyCode: 49,
        carbonModifiers: UInt32(optionKey) | UInt32(shiftKey),
        keyDisplay: "Space"
    )

    static let defaultTapToStartStop = HotkeyConfiguration(
        keyCode: 49,
        carbonModifiers: UInt32(controlKey) | UInt32(optionKey),
        keyDisplay: "Space"
    )

    static func from(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> HotkeyConfiguration {
        HotkeyConfiguration(
            keyCode: UInt32(keyCode),
            carbonModifiers: carbonModifiers(for: modifiers),
            keyDisplay: keyDisplay(for: keyCode, characters: characters)
        )
    }

    static func modifierOnly(modifiers: NSEvent.ModifierFlags) -> HotkeyConfiguration {
        HotkeyConfiguration(
            keyCode: modifierOnlyKeyCode,
            carbonModifiers: carbonModifiers(for: modifiers),
            keyDisplay: ""
        )
    }

    static func carbonModifiers(for modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    static func modifierDisplayName(for carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        return parts.joined(separator: " + ")
    }

    static func symbolModifierDisplayName(for carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        return parts.joined(separator: " ")
    }

    private static func keyDisplay(for keyCode: UInt16, characters: String?) -> String {
        if let characters {
            let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return prettyKeyName(for: trimmed)
            }
        }

        switch keyCode {
        case 36:
            return "Return"
        case 48:
            return "Tab"
        case 49:
            return "Space"
        case 51:
            return "Delete"
        case 53:
            return "Escape"
        case 123:
            return "Left Arrow"
        case 124:
            return "Right Arrow"
        case 125:
            return "Down Arrow"
        case 126:
            return "Up Arrow"
        default:
            return "Key \(keyCode)"
        }
    }

    private static func prettyKeyName(for text: String) -> String {
        switch text {
        case " ":
            return "Space"
        case "\r":
            return "Return"
        case "\t":
            return "Tab"
        case String(Character(UnicodeScalar(NSDeleteCharacter)!)):
            return "Delete"
        case String(Character(UnicodeScalar(NSEnterCharacter)!)):
            return "Enter"
        case String(Character(UnicodeScalar(0x1B)!)):
            return "Escape"
        default:
            return text.count == 1 ? text.uppercased() : text.capitalized
        }
    }

    private static func symbolKeyName(for text: String) -> String {
        switch text {
        case "Space":
            return "SPACE"
        case "Return":
            return "RETURN"
        case "Tab":
            return "TAB"
        case "Delete":
            return "DELETE"
        case "Escape":
            return "ESC"
        case "Left Arrow":
            return "←"
        case "Right Arrow":
            return "→"
        case "Down Arrow":
            return "↓"
        case "Up Arrow":
            return "↑"
        default:
            return text.uppercased()
        }
    }
}

struct HotkeyBinding: Equatable, Sendable, Identifiable {
    let action: HotkeyAction
    var isEnabled: Bool
    var shortcut: HotkeyConfiguration

    var id: String { action.rawValue }

    var displayName: String {
        shortcut.displayName
    }

    static let defaultHoldToTalk = HotkeyBinding(
        action: .holdToTalk,
        isEnabled: true,
        shortcut: .defaultHoldToTalk
    )

    static let defaultTapToStartStop = HotkeyBinding(
        action: .tapToStartStop,
        isEnabled: false,
        shortcut: .defaultTapToStartStop
    )
}

struct PermissionsSnapshot: Equatable {
    let microphoneGranted: Bool
    let accessibilityGranted: Bool
    let inputMonitoringGranted: Bool

    var allRequiredGranted: Bool {
        microphoneGranted && accessibilityGranted
    }
}
