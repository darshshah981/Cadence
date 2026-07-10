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
    case largeV3

    var id: String { rawValue }

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
        case .largeV3:
            return "Large v3"
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
        case .largeV3:
            return "large-v3"
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
        case .largeV3:
            return "~626 MB"
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
        case .largeV3:
            return "Most accurate"
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

enum DictationQualityPreset: String, CaseIterable, Identifiable, Sendable {
    case fast
    case everyday = "balanced"
    case bestAccuracy = "mostAccurate"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .everyday:
            return "Everyday"
        case .bestAccuracy:
            return "Best accuracy"
        }
    }

    var description: String {
        switch self {
        case .fast:
            return "For quick notes and short bursts."
        case .everyday:
            return "Recommended for everyday dictation."
        case .bestAccuracy:
            return "Best when accuracy matters more than speed."
        }
    }

    var model: WhisperModelOption {
        switch self {
        case .fast:
            return .baseEnglish
        case .everyday, .bestAccuracy:
            return .largeV3
        }
    }

    var decodingMode: WhisperDecodingMode {
        switch self {
        case .fast, .everyday:
            return .greedy
        case .bestAccuracy:
            return .beamSearch
        }
    }

    static func matching(_ configuration: TranscriptionConfiguration) -> DictationQualityPreset {
        if configuration.model == .largeV3, configuration.decodingMode == .beamSearch {
            return .bestAccuracy
        }

        if configuration.model == .largeV3 {
            return .everyday
        }

        return .fast
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
    var livePreviewEnabled: Bool = false
    var tapStopsOnNextKeyPress: Bool = false
    var appAwarePolishingEnabled: Bool = true
    var vocabularyText: String = ""

    var summary: String {
        "\(model.shortLabel) • \(decodingMode.shortLabel) • " +
        fillerWordPolicy.rawValue + " • " +
        (keepContext ? "context" : "isolated") + " • " +
        (trimSilence ? "trim" : "raw") + " • " +
        (normalizeAudio ? "normalize" : "natural")
    }
}

struct DictationTargetApplication: Equatable, Sendable {
    let bundleIdentifier: String
    let displayName: String

    init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    init?(runningApplication application: NSRunningApplication?) {
        guard let application,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }

        self.bundleIdentifier = bundleIdentifier
        self.displayName = application.localizedName ?? bundleIdentifier
    }
}

enum AppAwarePolishProfile: String, Sendable {
    case general
    case messaging
    case writing
    case code
}

struct AppAwarePolishResult: Equatable, Sendable {
    let text: String
    let insertionSuffix: String
    let profile: AppAwarePolishProfile

    var insertionText: String {
        text.isEmpty ? "" : text + insertionSuffix
    }
}

struct AppAwareTextPolisher {
    static func apply(
        to text: String,
        configuration: TranscriptionConfiguration,
        targetApplication: DictationTargetApplication?
    ) -> AppAwarePolishResult {
        let profile = Self.profile(for: targetApplication)
        let baseText = cleanInlineWhitespace(in: text)

        guard configuration.appAwarePolishingEnabled else {
            return AppAwarePolishResult(
                text: baseText,
                insertionSuffix: baseText.isEmpty ? "" : " ",
                profile: .general
            )
        }

        switch profile {
        case .messaging, .code:
            return AppAwarePolishResult(text: baseText, insertionSuffix: "", profile: profile)
        case .writing:
            let polishedText = addSentencePunctuationIfNeeded(to: baseText)
            return AppAwarePolishResult(text: polishedText, insertionSuffix: polishedText.isEmpty ? "" : " ", profile: profile)
        case .general:
            return AppAwarePolishResult(text: baseText, insertionSuffix: baseText.isEmpty ? "" : " ", profile: profile)
        }
    }

    static func profile(for targetApplication: DictationTargetApplication?) -> AppAwarePolishProfile {
        guard let targetApplication else { return .general }
        let bundleIdentifier = targetApplication.bundleIdentifier.lowercased()

        if matches(bundleIdentifier, exact: codeBundleIdentifiers, fragments: codeBundleFragments) {
            return .code
        }

        if matches(bundleIdentifier, exact: messagingBundleIdentifiers, fragments: messagingBundleFragments) {
            return .messaging
        }

        if matches(bundleIdentifier, exact: writingBundleIdentifiers, fragments: writingBundleFragments) {
            return .writing
        }

        return .general
    }

    private static let messagingBundleIdentifiers: Set<String> = [
        "com.apple.mobilesms",
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "net.whatsapp.whatsapp",
        "org.whispersystems.signal-desktop",
        "ru.keepcoder.telegram",
        "com.facebook.archon"
    ]

    private static let messagingBundleFragments = [
        "slack",
        "discord",
        "teams",
        "whatsapp",
        "telegram",
        "signal",
        "messenger"
    ]

    private static let writingBundleIdentifiers: Set<String> = [
        "com.apple.mail",
        "com.microsoft.outlook",
        "com.microsoft.word",
        "com.apple.notes",
        "com.apple.textedit",
        "com.apple.iwork.pages",
        "com.ulyssesapp.mac",
        "net.shinyfrog.bear"
    ]

    private static let writingBundleFragments = [
        "mail",
        "outlook",
        "word",
        "pages",
        "notes",
        "textedit",
        "ulysses",
        "bear",
        "obsidian",
        "notion"
    ]

    private static let codeBundleIdentifiers: Set<String> = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.sublimetext.4",
        "com.panic.nova"
    ]

    private static let codeBundleFragments = [
        "xcode",
        "vscode",
        "cursor",
        "terminal",
        "iterm",
        "warp",
        "wezterm",
        "ghostty",
        "sublime",
        "jetbrains",
        "intellij",
        "pycharm",
        "webstorm",
        "zed",
        "nova",
        "bbedit"
    ]

    private static func matches(_ bundleIdentifier: String, exact: Set<String>, fragments: [String]) -> Bool {
        exact.contains(bundleIdentifier) || fragments.contains { bundleIdentifier.contains($0) }
    }

    private static func cleanInlineWhitespace(in text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { line in
                line
                    .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func addSentencePunctuationIfNeeded(to text: String) -> String {
        guard !text.contains("\n") else { return text }
        guard text.split(whereSeparator: \.isWhitespace).count >= 4 else { return text }
        guard let lastScalar = text.unicodeScalars.last else { return text }

        let terminalPunctuation = CharacterSet(charactersIn: ".!?;:)]}\"'")
        if terminalPunctuation.contains(lastScalar) {
            return text
        }

        if CharacterSet.letters.union(.decimalDigits).contains(lastScalar) {
            return text + "."
        }

        return text
    }
}

struct AudioCaptureSessionMetrics: Sendable {
    let duration: TimeInterval
    let frameCount: Int
    let sampleRate: Double
    let speechDetected: Bool
    let speechFrameCount: Int
    let peakLevel: Double
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
    let analyticsSessionID: String?

    init(id: UUID = UUID(), text: String, createdAt: Date = .now, analyticsSessionID: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.analyticsSessionID = analyticsSessionID
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
    case preparingModel
    case transcribing
    case inserting
    case success
    case cancelled
    case error(message: String)

    var accessibilityLabel: String {
        switch self {
        case .recording(let triggerMode, _):
            return triggerMode == .tapToStartStop ? "Continuous dictation is listening" : "Dictation is listening"
        case .preparingModel:
            return "Preparing the speech model"
        case .transcribing:
            return "Transcribing dictation"
        case .inserting:
            return "Inserting dictation"
        case .success:
            return "Dictation inserted"
        case .cancelled:
            return "Dictation cancelled"
        case .error(let message):
            return message
        }
    }

    var accessibilityHint: String? {
        switch self {
        case .recording(.tapToStartStop, _):
            return "Use Stop to finish dictating, or Cancel to discard this session."
        case .recording(.holdToTalk, _):
            return "Release the shortcut to finish dictating."
        default:
            return nil
        }
    }
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
    var sidedModifierKeyCodes: Set<UInt16> = []

    var displayName: String {
        let modifiers = modifierDisplayName
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
        var parts = modifierSymbolParts
        if !isModifierOnly && !keyDisplay.isEmpty { parts.append(Self.symbolKeyName(for: keyDisplay)) }
        return parts
    }

    var requiresSpecificModifierSides: Bool {
        !sidedModifierKeyCodes.isEmpty
    }

    private var modifierDisplayName: String {
        if !sidedModifierKeyCodes.isEmpty {
            return sidedModifierKeyCodes
                .sorted { Self.modifierSortOrder(for: $0) < Self.modifierSortOrder(for: $1) }
                .map(Self.sidedModifierDisplayName)
                .joined(separator: " + ")
        }

        return Self.modifierDisplayName(for: carbonModifiers)
    }

    private var modifierSymbolParts: [String] {
        if !sidedModifierKeyCodes.isEmpty {
            return sidedModifierKeyCodes
                .sorted { Self.modifierSortOrder(for: $0) < Self.modifierSortOrder(for: $1) }
                .map(Self.sidedModifierSymbolName)
        }

        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
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
        keyCode == other.keyCode &&
            carbonModifiers == other.carbonModifiers &&
            sidedModifierKeyCodes == other.sidedModifierKeyCodes
    }

    func matches(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, activeModifierKeyCodes: Set<UInt16>) -> Bool {
        guard !isModifierOnly, self.keyCode == UInt32(keyCode) else { return false }
        guard Self.carbonModifiers(for: modifiers) == carbonModifiers else { return false }
        guard !requiresSpecificModifierSides else {
            return sidedModifierKeyCodes.isSubset(of: activeModifierKeyCodes)
        }
        return true
    }

    func matches(modifiers: NSEvent.ModifierFlags, activeModifierKeyCodes: Set<UInt16>) -> Bool {
        let carbon = Self.carbonModifiers(for: modifiers)
        guard isModifierOnly, carbon == carbonModifiers, carbon != 0 else { return false }
        guard !requiresSpecificModifierSides else {
            return sidedModifierKeyCodes.isSubset(of: activeModifierKeyCodes)
        }
        return true
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
        from(
            keyCode: keyCode,
            modifiers: modifiers,
            characters: characters,
            sidedModifierKeyCodes: []
        )
    }

    static func from(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String?,
        sidedModifierKeyCodes: Set<UInt16>
    ) -> HotkeyConfiguration {
        HotkeyConfiguration(
            keyCode: UInt32(keyCode),
            carbonModifiers: carbonModifiers(for: modifiers),
            keyDisplay: keyDisplay(for: keyCode, characters: characters),
            sidedModifierKeyCodes: sanitizedSidedModifierKeyCodes(sidedModifierKeyCodes, modifiers: modifiers)
        )
    }

    static func modifierOnly(modifiers: NSEvent.ModifierFlags) -> HotkeyConfiguration {
        modifierOnly(modifiers: modifiers, sidedModifierKeyCodes: [])
    }

    static func modifierOnly(
        modifiers: NSEvent.ModifierFlags,
        sidedModifierKeyCodes: Set<UInt16>
    ) -> HotkeyConfiguration {
        HotkeyConfiguration(
            keyCode: modifierOnlyKeyCode,
            carbonModifiers: carbonModifiers(for: modifiers),
            keyDisplay: "",
            sidedModifierKeyCodes: sanitizedSidedModifierKeyCodes(sidedModifierKeyCodes, modifiers: modifiers)
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

    static func symbolModifierDisplayName(for sidedModifierKeyCodes: Set<UInt16>, fallback carbonModifiers: UInt32) -> String {
        guard !sidedModifierKeyCodes.isEmpty else {
            return symbolModifierDisplayName(for: carbonModifiers)
        }

        return sidedModifierKeyCodes
            .sorted { modifierSortOrder(for: $0) < modifierSortOrder(for: $1) }
            .map(sidedModifierSymbolName)
            .joined(separator: " ")
    }

    static func updatedActiveModifierKeyCodes(
        _ activeModifierKeyCodes: Set<UInt16>,
        with event: NSEvent
    ) -> Set<UInt16> {
        guard isSidedModifierKey(event.keyCode) else { return activeModifierKeyCodes }

        var updated = activeModifierKeyCodes
        let flag = modifierFlag(forSidedKeyCode: event.keyCode)
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).contains(flag) {
            updated.insert(event.keyCode)
        } else {
            updated.remove(event.keyCode)
        }
        return updated
    }

    static func activeSidedModifierKeyCodes(
        from activeModifierKeyCodes: Set<UInt16>,
        modifiers: NSEvent.ModifierFlags
    ) -> Set<UInt16> {
        sanitizedSidedModifierKeyCodes(activeModifierKeyCodes, modifiers: modifiers)
    }

    static func sidedModifierKeyCodes(from encoded: String?) -> Set<UInt16> {
        guard let encoded, !encoded.isEmpty else { return [] }
        return Set(encoded.split(separator: ",").compactMap { UInt16($0) })
    }

    static func encodedSidedModifierKeyCodes(_ keyCodes: Set<UInt16>) -> String {
        keyCodes.sorted().map(String.init).joined(separator: ",")
    }

    private static func sanitizedSidedModifierKeyCodes(
        _ keyCodes: Set<UInt16>,
        modifiers: NSEvent.ModifierFlags
    ) -> Set<UInt16> {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        return Set(keyCodes.filter { keyCode in
            guard isSidedModifierKey(keyCode) else { return false }
            return flags.contains(modifierFlag(forSidedKeyCode: keyCode))
        })
    }

    private static func isSidedModifierKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62:
            return true
        default:
            return false
        }
    }

    private static func modifierFlag(forSidedKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 54, 55:
            return .command
        case 56, 60:
            return .shift
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        default:
            return []
        }
    }

    private static func sidedModifierDisplayName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 54:
            return "Right Command"
        case 55:
            return "Left Command"
        case 56:
            return "Left Shift"
        case 58:
            return "Left Option"
        case 59:
            return "Left Control"
        case 60:
            return "Right Shift"
        case 61:
            return "Right Option"
        case 62:
            return "Right Control"
        default:
            return "Modifier"
        }
    }

    private static func sidedModifierSymbolName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 54:
            return "R⌘"
        case 55:
            return "L⌘"
        case 56:
            return "L⇧"
        case 58:
            return "L⌥"
        case 59:
            return "L⌃"
        case 60:
            return "R⇧"
        case 61:
            return "R⌥"
        case 62:
            return "R⌃"
        default:
            return "Mod"
        }
    }

    private static func modifierSortOrder(for keyCode: UInt16) -> Int {
        switch keyCode {
        case 59:
            return 10
        case 62:
            return 11
        case 58:
            return 20
        case 61:
            return 21
        case 56:
            return 30
        case 60:
            return 31
        case 55:
            return 40
        case 54:
            return 41
        default:
            return 100 + Int(keyCode)
        }
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
    var screenRecordingGranted: Bool = false

    var allRequiredGranted: Bool {
        microphoneGranted && accessibilityGranted && inputMonitoringGranted
    }
}
