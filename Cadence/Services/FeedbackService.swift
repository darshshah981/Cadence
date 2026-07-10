import AppKit
import Foundation
import OSLog

private let feedbackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Feedback"
)

@MainActor
protocol FeedbackServing: AnyObject {
    var isEnabled: Bool { get set }
    func playActivationSound()
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
    static let key = "Cadence.dictationSoundFeedbackEnabled"

    static func load(from defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }

    @MainActor
    static func set(
        _ enabled: Bool,
        defaults: UserDefaults,
        service: FeedbackServing
    ) {
        defaults.set(enabled, forKey: key)
        service.isEnabled = enabled
    }
}

final class SoundFeedbackService: FeedbackServing {
    var isEnabled: Bool

    private let soundName = "Tink"

    init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }

    func playActivationSound() {
        guard isEnabled else { return }
        guard let sound = NSSound(named: soundName) else {
            feedbackLogger.warning("Activation sound '\(self.soundName, privacy: .public)' not found")
            return
        }
        sound.play()
    }
}
