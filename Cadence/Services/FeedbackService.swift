import AppKit
import Foundation
import OSLog

private let feedbackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Feedback"
)

@MainActor
protocol FeedbackServing: AnyObject {
    var isActivationEnabled: Bool { get set }
    var isCompletionEnabled: Bool { get set }
    func playActivationSound()
    func playScribeActivationSound()
    func playScribeProcessingSound()
    func playScribeCompletionSound()
    func playCompletionSound()
}

extension FeedbackServing {
    func playScribeActivationSound() {
        playActivationSound()
    }

    func playCompletionSound() {
        playActivationSound()
    }

    func playScribeProcessingSound() {
        playActivationSound()
    }

    func playScribeCompletionSound() {
        playCompletionSound()
    }
}

enum DictationActivationFeedbackEvent: Equatable {
    case listeningStarted
    case audioUpdated
    case stopped
    case cancelled
    case failed
}

@MainActor
final class DictationActivationFeedbackGate {
    private let service: FeedbackServing
    private var isListeningSessionActive = false

    init(service: FeedbackServing) {
        self.service = service
    }

    func handle(_ event: DictationActivationFeedbackEvent) {
        switch event {
        case .listeningStarted:
            guard !isListeningSessionActive else { return }
            isListeningSessionActive = true
            service.playActivationSound()
        case .audioUpdated:
            break
        case .stopped, .cancelled, .failed:
            isListeningSessionActive = false
        }
    }
}

enum DictationSoundFeedbackPreference {
    static let legacyKey = "Cadence.dictationSoundFeedbackEnabled"
    static let activationKey = "Cadence.dictationActivationSoundEnabled"
    static let completionKey = "Cadence.dictationCompletionSoundEnabled"

    static func loadActivation(from defaults: UserDefaults) -> Bool {
        load(key: activationKey, from: defaults)
    }

    static func loadCompletion(from defaults: UserDefaults) -> Bool {
        load(key: completionKey, from: defaults)
    }

    private static func load(key: String, from defaults: UserDefaults) -> Bool {
        if let value = defaults.object(forKey: key) as? Bool {
            return value
        }
        return (defaults.object(forKey: legacyKey) as? Bool) ?? true
    }

    @MainActor
    static func setActivation(
        _ enabled: Bool,
        defaults: UserDefaults,
        service: FeedbackServing
    ) {
        defaults.set(enabled, forKey: activationKey)
        service.isActivationEnabled = enabled
    }

    @MainActor
    static func setCompletion(
        _ enabled: Bool,
        defaults: UserDefaults,
        service: FeedbackServing
    ) {
        defaults.set(enabled, forKey: completionKey)
        service.isCompletionEnabled = enabled
    }
}

final class SoundFeedbackService: FeedbackServing {
    var isActivationEnabled: Bool
    var isCompletionEnabled: Bool

    private let soundName = "Tink"
    private let completionSoundName = "Pop"
    private let scribeActivationSoundName = "Hero"
    private let scribeProcessingSoundName = "Purr"
    private let scribeCompletionSoundName = "Glass"

    init(isActivationEnabled: Bool = true, isCompletionEnabled: Bool = true) {
        self.isActivationEnabled = isActivationEnabled
        self.isCompletionEnabled = isCompletionEnabled
    }

    func playActivationSound() {
        guard isActivationEnabled else { return }
        guard let sound = NSSound(named: soundName) else {
            feedbackLogger.warning("Activation sound '\(self.soundName, privacy: .public)' not found")
            return
        }
        sound.play()
    }

    func playCompletionSound() {
        guard isCompletionEnabled else { return }
        guard let sound = NSSound(named: completionSoundName) else {
            guard let fallback = NSSound(named: soundName) else { return }
            fallback.play()
            return
        }
        sound.play()
    }

    func playScribeActivationSound() {
        guard isActivationEnabled else { return }
        guard let sound = NSSound(named: scribeActivationSoundName) else {
            playActivationSound()
            return
        }
        sound.play()
    }

    func playScribeProcessingSound() {
        guard isActivationEnabled else { return }
        guard let sound = NSSound(named: scribeProcessingSoundName) else {
            playActivationSound()
            return
        }
        sound.play()
    }

    func playScribeCompletionSound() {
        guard isCompletionEnabled else { return }
        guard let sound = NSSound(named: scribeCompletionSoundName) else {
            playCompletionSound()
            return
        }
        sound.play()
    }
}
