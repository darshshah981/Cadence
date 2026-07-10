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
