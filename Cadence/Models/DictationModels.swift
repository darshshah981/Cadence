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
            return "Press to Dictate"
        case .tapToStartStop:
            return "Toggle Recording"
        }
    }

    var shortDescription: String {
        switch self {
        case .holdToTalk:
            return "Press and hold to record, release to finish."
        case .tapToStartStop:
            return "Press once to start, then press the shortcut again to stop."
        }
    }

    var showsLockIndicator: Bool {
        self == .tapToStartStop
    }
}

struct DoublePressLatch: Equatable, Sendable {
    let maxInterval: TimeInterval
    private(set) var previousTapTime: TimeInterval?

    init(maxInterval: TimeInterval = 0.38) {
        self.maxInterval = maxInterval
    }

    mutating func registerTap(at time: TimeInterval) -> Bool {
        if let previousTapTime {
            let interval = time - previousTapTime
            if interval >= 0, interval <= maxInterval {
                self.previousTapTime = nil
                return true
            }
        }
        previousTapTime = time
        return false
    }

    mutating func reset() {
        previousTapTime = nil
    }
}

enum DictationQuickTapDecision: Equatable, Sendable {
    case none
    case startToggleRecording
    case stopToggleRecording
}

struct DictationQuickTapGesture: Equatable, Sendable {
    private var latch = DoublePressLatch()

    mutating func register(
        state: DictationSessionState,
        activeTriggerMode: DictationTriggerMode?,
        at time: TimeInterval
    ) -> DictationQuickTapDecision {
        if state == .listening, activeTriggerMode == .tapToStartStop {
            latch.reset()
            return .stopToggleRecording
        }

        guard state == .idle || isError(state) else {
            latch.reset()
            return .none
        }

        guard latch.registerTap(at: time) else { return .none }
        latch.reset()
        return .startToggleRecording
    }

    mutating func reset() {
        latch.reset()
    }

    private func isError(_ state: DictationSessionState) -> Bool {
        if case .error = state { return true }
        return false
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
            return "Keep conversational fillers such as um and uh."
        case .remove:
            return "Remove unambiguous fillers such as um and uh."
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
    var pressEnterCommandEnabled: Bool = false
    var pressEnterCommandPhrase: String = DictationCommandPhrase.defaultValue
    var vocabularyText: String = ""

    var summary: String {
        "\(model.shortLabel) • \(decodingMode.shortLabel) • " +
        fillerWordPolicy.rawValue + " • " +
        (keepContext ? "context" : "isolated") + " • " +
        (trimSilence ? "trim" : "raw") + " • " +
        (normalizeAudio ? "normalize" : "natural")
    }
}

enum DictationCommandPhrase {
    static let defaultValue = "press enter"
    static let maximumLength = 48

    static func sanitizedForStorage(_ phrase: String) -> String {
        let singleLine = phrase
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(maximumLength))
    }

    static func normalizedWords(_ phrase: String) -> [Substring] {
        phrase.split(whereSeparator: \.isWhitespace)
    }
}

struct DictationCommandInterpretation: Equatable, Sendable {
    let text: String
    let shouldPressReturn: Bool
}

enum DictationCommandInterpreter {
    static func interpret(
        _ text: String,
        pressEnterEnabled: Bool,
        commandPhrase: String = DictationCommandPhrase.defaultValue
    ) -> DictationCommandInterpretation {
        let phraseWords = DictationCommandPhrase.normalizedWords(commandPhrase)
        let escapedPhrase = phraseWords
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
        let trailingCommandPattern =
            #"(?:[\s,;:—-]+|^)"# + escapedPhrase + #"[\s.!?]*$"#

        guard pressEnterEnabled,
              !phraseWords.isEmpty,
              let commandRange = text.range(
                of: trailingCommandPattern,
                options: [.regularExpression, .caseInsensitive]
              ) else {
            return DictationCommandInterpretation(
                text: text,
                shouldPressReturn: false
            )
        }

        return DictationCommandInterpretation(
            text: String(text[..<commandRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines),
            shouldPressReturn: true
        )
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

enum TerminalApplication {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty"
    ]

    static func matches(bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier.lowercased())
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

    private static let codeBundleIdentifiers: Set<String> = Set([
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.todesktop.230313mzl4w4u92",
        "com.sublimetext.4",
        "com.panic.nova"
    ]).union(TerminalApplication.bundleIdentifiers)

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
    case idle
    case recording(triggerMode: DictationTriggerMode, showsHint: Bool)
    case scribeRecording
    case preparingModel
    case transcribing
    case scribeTranscribing
    case scribed
    case inserting
    case copying
    case copied
    case success
    case cancelled
    case error(message: String)

    var accessibilityLabel: String {
        switch self {
        case .idle:
            return "Cadence is ready"
        case .recording(let triggerMode, _):
            return triggerMode == .tapToStartStop ? "Continuous dictation is listening" : "Dictation is listening"
        case .scribeRecording:
            return "Scribe is listening"
        case .preparingModel:
            return "Preparing the speech model"
        case .transcribing:
            return "Transcribing dictation"
        case .scribeTranscribing:
            return "Transcribing for Scribe"
        case .scribed:
            return "Scribe draft ready"
        case .inserting:
            return "Inserting dictation"
        case .copying:
            return "Copying dictation"
        case .copied:
            return "Dictation copied"
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
            return "Press the Dictation shortcut again to finish."
        case .recording(.holdToTalk, _):
            return "Release the shortcut to finish dictating."
        case .scribeRecording:
            return "Press the Scribe shortcut again when you finish speaking."
        default:
            return nil
        }
    }
}

enum HUDMetrics {
    static let idleHitSize = NSSize(width: 44, height: 44)
    static let idleMarkSize = NSSize(width: 44, height: 38)
    static let screenInset: CGFloat = 16
    static let panelHeight: CGFloat = 44
    static let expandedTraySize = NSSize(width: 240, height: panelHeight)
    static let pillHeight: CGFloat = 38
    static let compactWidth: CGFloat = 280
    static let holdHintWidth: CGFloat = 360
    static let statusWidth: CGFloat = 340
    static let subtitleSize = NSSize(width: 320, height: 36)
    static let subtitleGap: CGFloat = 8
    static let waveformWidth: CGFloat = 112
    static let waveformHeight: CGFloat = 28
    static let waveformBarWidth: CGFloat = 3
    static let waveformBarGap: CGFloat = 3
    // Deliberately subordinate to the 38 pt listening pill, but close enough
    // in height to read as a companion surface instead of a tiny badge.
    static let lockIndicatorSize = NSSize(width: 32, height: 32)
    static let lockIndicatorGap: CGFloat = 5
}

enum HUDContentSizing {
    static let horizontalPadding: CGFloat = 12
    static let iconSize: CGFloat = 16
    static let iconNameGap: CGFloat = 4
    static let contentGap: CGFloat = 8
    static let applicationNameCharacterLimit = 14
    static let applicationNameMinimumWidth: CGFloat = 28
    static let applicationNameMaximumWidth: CGFloat = 84
    static let statusTextMaximumWidth: CGFloat = 120

    static func applicationNameWidth(_ name: String) -> CGFloat {
        if name.count > applicationNameCharacterLimit {
            return applicationNameMaximumWidth
        }
        let capped = String(name.prefix(applicationNameCharacterLimit))
        return min(
            applicationNameMaximumWidth,
            max(applicationNameMinimumWidth, measuredWidth(capped, size: 10, weight: .medium))
        )
    }

    static func width(
        for presentation: HUDPresentation,
        applicationName: String
    ) -> CGFloat {
        switch presentation.visualState {
        case .idle:
            return presentation.isExpanded
                ? HUDMetrics.expandedTraySize.width
                : HUDMetrics.idleHitSize.width
        case .recording(let triggerMode, let showsHint):
            return recordingWidth(
                applicationName: applicationName,
                triggerMode: triggerMode,
                showsHint: showsHint
            )
        case .scribeRecording:
            return activeWidth(applicationName: applicationName)
        case .error:
            // Preserve the recording tray's width so feedback replaces the
            // waveform instead of causing a second geometry change.
            return activeWidth(applicationName: applicationName)
        case .preparingModel, .transcribing, .scribeTranscribing, .scribed,
             .inserting, .copying, .copied, .success, .cancelled:
            // Once dictation has opened the active pill, every processing and
            // completion phase keeps that exact footprint. Foreground content
            // can transition without making the capsule breathe between
            // waveform, transcribing, inserted, and copied states.
            return activeWidth(applicationName: applicationName)
        }
    }

    private static func activeWidth(applicationName: String) -> CGFloat {
        recordingWidth(
            applicationName: applicationName,
            triggerMode: .holdToTalk,
            showsHint: false
        )
    }

    private static func recordingWidth(
        applicationName: String,
        triggerMode: DictationTriggerMode,
        showsHint: Bool
    ) -> CGFloat {
        var width = horizontalPadding * 2
            + iconSize
            + iconNameGap
            + applicationNameWidth(applicationName)
            + contentGap
            + HUDMetrics.waveformWidth

        if triggerMode == .holdToTalk, showsHint {
            width += contentGap + measuredWidth("Release to stop", size: 11, weight: .medium)
        }
        return ceil(width)
    }

    private static func measuredWidth(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct HUDMotionTuning: Equatable, Sendable {
    static let `default` = HUDMotionTuning(
        pillResponse: 0.34,
        micFadeOutDuration: 0.12,
        appCueFadeInDuration: 0.18,
        waveformFadeInDuration: 0.24
    )

    var pillResponse: TimeInterval
    var micFadeOutDuration: TimeInterval
    var appCueFadeInDuration: TimeInterval
    var waveformFadeInDuration: TimeInterval
}

enum HUDMotion {
    static let waveformAttackRate = -log(0.6) * 60
    static let waveformReleaseRate = -log(0.92) * 60
    static let stableTolerance = 0.001
    static let activationSweepDuration: TimeInterval = 0.42
    static let foregroundTravelDistance: CGFloat = 10
    private static let waveformCharacter = [
        0.76, 1.00, 0.68, 0.91, 0.61, 0.84, 0.72, 0.96,
        0.65, 0.88, 0.74, 0.98, 0.63, 0.82, 0.70, 0.93
    ]
    private static let waveformResponseCharacter = [
        0.86, 1.08, 0.92, 1.16, 0.81, 1.02, 0.89, 1.12,
        0.84, 1.05, 0.94, 1.14, 0.79, 1.00, 0.88, 1.10
    ]

    static func smoothProgress(elapsed: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let progress = max(0, min(1, elapsed / duration))
        // Smootherstep keeps both velocity and acceleration continuous at the
        // endpoints, which prevents a visible catch as a width morph starts or
        // settles into a newly measured pill size.
        return progress * progress * progress
            * (progress * (progress * 6 - 15) + 10)
    }

    static func interpolateWidth(from: CGFloat, to: CGFloat, progress: Double) -> CGFloat {
        let progress = CGFloat(max(0, min(1, progress)))
        return from + (to - from) * progress
    }

    static func activationSweepLevels(progress: Double, target: [Double]) -> [Double] {
        let progress = max(0, min(1, progress))
        let count = target.count
        guard count > 0 else { return [] }

        // Begin with a fully formed crest on the first bar. Starting the
        // Gaussian offscreen exposed only its thin tail before the pulse grew.
        let center = progress * Double(max(0, count - 1))
        let settle = smoothProgress(
            elapsed: max(0, progress - 0.82),
            duration: 0.18
        )
        let pulseStrength = 0.92 * (1 - settle)

        return target.enumerated().map { index, targetLevel in
            let distance = (Double(index) - center) / 1.18
            let primary = exp(-0.5 * distance * distance)
            let trailingDistance = (Double(index) - center + 2.15) / 0.92
            let trailingCrest = exp(-0.5 * trailingDistance * trailingDistance) * 0.28
            let character = waveformCharacter[index % waveformCharacter.count]
            let pulse = max(primary * character, trailingCrest) * pulseStrength
            return max(0, min(1, targetLevel * settle + pulse))
        }
    }

    static func characterizedWaveformLevels(_ levels: [Double]) -> [Double] {
        guard !levels.isEmpty else { return [] }
        return levels.enumerated().map { index, level in
            let left = levels[max(0, index - 1)]
            let right = levels[min(levels.count - 1, index + 1)]
            let localEnergy = max(0, min(1, level * 0.68 + left * 0.19 + right * 0.13))
            let character = waveformCharacter[index % waveformCharacter.count]
            return max(0, min(1, localEnergy * character))
        }
    }

    static func waveformResponseScale(forBar index: Int) -> Double {
        waveformResponseCharacter[index % waveformResponseCharacter.count]
    }

    static func incomingOpacity(
        for presentation: HUDPresentation,
        hasPreviousPresentation: Bool,
        elapsed: TimeInterval,
        duration: TimeInterval
    ) -> Double {
        guard hasPreviousPresentation else { return 1 }
        // The collapsed mic is the HUD's resting affordance. Keeping it fully
        // visible during the return transition avoids a final-frame cross-fade
        // race that can otherwise leave the icon transparent after collapse.
        if presentation.visualState == .idle, !presentation.isExpanded {
            return 1
        }
        return smoothProgress(elapsed: elapsed, duration: duration)
    }

    static func collapsingContentOpacity(
        elapsed: TimeInterval,
        pillResponse: TimeInterval
    ) -> Double {
        let duration = min(0.14, pillResponse * 0.42)
        return 1 - smoothProgress(elapsed: elapsed, duration: duration)
    }
}

enum HUDActiveContentTransition {
    static let duration: TimeInterval = 0.14
    private static let outgoingFadeDuration: TimeInterval = 0.075
    private static let incomingFadeDelay: TimeInterval = 0.05
    private static let incomingFadeDuration: TimeInterval = 0.09

    static func outgoingOpacity(elapsed: TimeInterval) -> Double {
        1 - HUDMotion.smoothProgress(
            elapsed: elapsed,
            duration: outgoingFadeDuration
        )
    }

    static func incomingOpacity(elapsed: TimeInterval) -> Double {
        HUDMotion.smoothProgress(
            elapsed: max(0, elapsed - incomingFadeDelay),
            duration: incomingFadeDuration
        )
    }

    static func isActive(_ presentation: HUDPresentation) -> Bool {
        presentation.visualState != .idle
    }

    static func shouldDefer(
        current: HUDPresentation,
        requested: HUDPresentation,
        isReplacementAnimating: Bool
    ) -> Bool {
        guard isReplacementAnimating,
              current != requested,
              isActive(current),
              isActive(requested) else {
            return false
        }
        // A new recording is direct user feedback and must never wait behind a
        // processing label. Processing/terminal updates may coalesce while the
        // current short replacement completes.
        if case .recording = requested.visualState {
            return false
        }
        if requested.visualState == .scribeRecording {
            return false
        }
        return true
    }
}

enum HUDApplicationCueTransition {
    static func keepsCueStable(
        from previous: HUDVisualState,
        to current: HUDVisualState
    ) -> Bool {
        isStatus(previous) && isStatus(current)
    }

    private static func isStatus(_ state: HUDVisualState) -> Bool {
        switch state {
        case .idle, .recording, .scribeRecording:
            return false
        case .preparingModel, .transcribing, .scribeTranscribing, .scribed,
             .inserting, .copying,
             .copied, .success, .cancelled, .error:
            return true
        }
    }
}

enum HUDTerminalTiming {
    static func displayMilliseconds(for visualState: HUDVisualState) -> Int {
        guard case .error(let message) = visualState else { return 900 }
        return min(6_000, max(1_500, 650 + message.count * 55))
    }
}

struct HUDCornerRadii: Equatable {
    let topLeading: CGFloat
    let bottomLeading: CGFloat
    let bottomTrailing: CGFloat
    let topTrailing: CGFloat
}

enum HUDPosition: String, CaseIterable, Equatable {
    case bottomCenter
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    static var allCases: [HUDPosition] {
        [.topLeft, .topRight, .bottomLeft, .bottomCenter, .bottomRight]
    }

    var accessibilityName: String {
        switch self {
        case .bottomCenter: "Bottom center"
        case .bottomRight: "Bottom right"
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        }
    }

    var cornerRadii: HUDCornerRadii {
        let radius: CGFloat = 22
        return HUDCornerRadii(
            topLeading: radius,
            bottomLeading: radius,
            bottomTrailing: radius,
            topTrailing: radius
        )
    }

    func visibleMarkFrame(in panelFrame: NSRect) -> NSRect {
        let markSize = HUDMetrics.idleMarkSize
        let origin = NSPoint(
            x: panelFrame.midX - markSize.width / 2,
            y: panelFrame.midY - markSize.height / 2
        )
        return NSRect(origin: origin, size: markSize)
    }

    func origin(screenFrame: NSRect, visibleFrame: NSRect, hudSize: NSSize) -> NSPoint {
        let inset = HUDMetrics.screenInset
        switch self {
        case .bottomCenter:
            return NSPoint(
                x: screenFrame.midX - hudSize.width / 2,
                y: visibleFrame.minY + inset
            )
        case .bottomRight:
            return NSPoint(x: visibleFrame.maxX - hudSize.width - inset, y: visibleFrame.minY + inset)
        case .topLeft:
            return NSPoint(x: visibleFrame.minX + inset, y: visibleFrame.maxY - hudSize.height - inset)
        case .topRight:
            return NSPoint(x: visibleFrame.maxX - hudSize.width - inset, y: visibleFrame.maxY - hudSize.height - inset)
        case .bottomLeft:
            return NSPoint(x: visibleFrame.minX + inset, y: visibleFrame.minY + inset)
        }
    }

    static func nearest(to point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect, hudSize: NSSize) -> HUDPosition {
        var best = HUDPosition.bottomRight
        var bestDistance = CGFloat.infinity
        for position in HUDPosition.allCases {
            let origin = position.origin(screenFrame: screenFrame, visibleFrame: visibleFrame, hudSize: hudSize)
            let center = NSPoint(x: origin.x + hudSize.width / 2, y: origin.y + hudSize.height / 2)
            let dx = point.x - center.x
            let dy = point.y - center.y
            let distance = sqrt(dx * dx + dy * dy)
            if distance < bestDistance {
                bestDistance = distance
                best = position
            }
        }
        return best
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

    static let logoIdle = HUDState(
        visualState: .idle,
        subtitle: "",
        level: 0,
        waveformLevels: Array(repeating: 0, count: 16),
        isVisible: true,
        showsSubtitle: false
    )
}

enum HUDHideDuration: String, CaseIterable, Sendable {
    case tenMinutes
    case oneHour
    case untilNextSession

    var seconds: TimeInterval? {
        switch self {
        case .tenMinutes: return 600
        case .oneHour: return 3600
        case .untilNextSession: return nil
        }
    }

    var displayName: String {
        switch self {
        case .tenMinutes: "Hide for 10 minutes"
        case .oneHour: "Hide for 1 hour"
        case .untilNextSession: "Hide until next session"
        }
    }
}

enum HotkeyAction: String, CaseIterable, Identifiable, Sendable {
    case holdToTalk
    case tapToStartStop
    case scribe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdToTalk:
            return "Press to Dictate"
        case .tapToStartStop:
            return "Toggle Recording"
        case .scribe:
            return "Scribe"
        }
    }

    var shortDescription: String {
        switch self {
        case .holdToTalk:
            return "Hold to dictate, or double-press the same shortcut to lock recording. Function (fn) is the default."
        case .tapToStartStop:
            return "Press once to start, then press the shortcut again to stop. Use 2 or more keys total."
        case .scribe:
            return "Open Scribe to draft, respond, or edit. Use 2 or more keys total."
        }
    }

    var dictationTriggerMode: DictationTriggerMode? {
        switch self {
        case .holdToTalk:
            return .holdToTalk
        case .tapToStartStop:
            return .tapToStartStop
        case .scribe:
            return nil
        }
    }

    func supports(_ shortcut: HotkeyConfiguration) -> Bool {
        switch self {
        case .holdToTalk:
            return shortcut.componentCount <= 2
        case .tapToStartStop:
            return shortcut.componentCount >= 2
        case .scribe:
            return shortcut.componentCount >= 2
        }
    }

    var shortcutRuleDescription: String {
        switch self {
        case .holdToTalk:
            return "Use at most 2 keys total."
        case .tapToStartStop:
            return "Use at least 2 keys total."
        case .scribe:
            return "Use at least 2 keys total."
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
            var parts = sidedModifierKeyCodes
                .sorted { Self.modifierSortOrder(for: $0) < Self.modifierSortOrder(for: $1) }
                .map(Self.sidedModifierDisplayName)
            if carbonModifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.insert("Fn", at: 0) }
            return parts.joined(separator: " + ")
        }

        return Self.modifierDisplayName(for: carbonModifiers)
    }

    private var modifierSymbolParts: [String] {
        if !sidedModifierKeyCodes.isEmpty {
            var parts = sidedModifierKeyCodes
                .sorted { Self.modifierSortOrder(for: $0) < Self.modifierSortOrder(for: $1) }
                .map(Self.sidedModifierSymbolName)
            if carbonModifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.insert("fn", at: 0) }
            return parts
        }

        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if carbonModifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.append("fn") }
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
        keyCode: modifierOnlyKeyCode,
        carbonModifiers: UInt32(kEventKeyModifierFnMask),
        keyDisplay: ""
    )

    static let defaultTapToStartStop = HotkeyConfiguration(
        keyCode: 49,
        carbonModifiers: UInt32(controlKey),
        keyDisplay: "Space",
        sidedModifierKeyCodes: [59]
    )

    static let defaultScribe = HotkeyConfiguration(
        keyCode: modifierOnlyKeyCode,
        carbonModifiers: UInt32(kEventKeyModifierFnMask) | UInt32(controlKey),
        keyDisplay: "",
        sidedModifierKeyCodes: [59]
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
        if modifiers.contains(.function) { carbon |= UInt32(kEventKeyModifierFnMask) }
        return carbon
    }

    static func modifierDisplayName(for carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        if carbonModifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.append("Fn") }
        return parts.joined(separator: " + ")
    }

    static func symbolModifierDisplayName(for carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if carbonModifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.append("fn") }
        return parts.joined(separator: " ")
    }

    static func symbolModifierDisplayName(for sidedModifierKeyCodes: Set<UInt16>, fallback carbonModifiers: UInt32) -> String {
        guard !sidedModifierKeyCodes.isEmpty else {
            return symbolModifierDisplayName(for: carbonModifiers)
        }

        var parts = sidedModifierKeyCodes
            .sorted { modifierSortOrder(for: $0) < modifierSortOrder(for: $1) }
            .map(sidedModifierSymbolName)
        if carbonModifiers & UInt32(kEventKeyModifierFnMask) != 0 { parts.insert("fn", at: 0) }
        return parts.joined(separator: " ")
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
        let flags = modifiers.intersection([.command, .option, .control, .shift, .function])
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
        modifierFlag(forKeyCode: keyCode) ?? []
    }

    static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55:
            return .command
        case 56, 60:
            return .shift
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        case 63:
            return .function
        default:
            return nil
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
        isEnabled: true,
        shortcut: .defaultTapToStartStop
    )

    static let defaultScribe = HotkeyBinding(
        action: .scribe,
        isEnabled: true,
        shortcut: .defaultScribe
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

    var missingRequiredPermissionNames: [String] {
        var names: [String] = []
        if !microphoneGranted {
            names.append("Microphone")
        }
        if !accessibilityGranted {
            names.append("Accessibility")
        }
        if !inputMonitoringGranted {
            names.append("Input Monitoring")
        }
        return names
    }

    var scribePermissionMessage: String? {
        let names = missingRequiredPermissionNames
        guard !names.isEmpty else { return nil }

        let list: String
        switch names.count {
        case 1:
            list = names[0]
        case 2:
            list = names.joined(separator: " and ")
        default:
            list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
        return "Allow \(list) access before using Scribe."
    }
}
