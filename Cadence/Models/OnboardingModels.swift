import Foundation

enum OnboardingStep: String, CaseIterable, Codable, Identifiable, Sendable {
    case welcome
    case privacy
    case permissions
    case microphone
    case dictation
    case scribe
    case personalization
    case ready

    var id: String { rawValue }
}

struct OnboardingProgress: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let fresh = OnboardingProgress(stepIndex: 0, isComplete: false, wasSkipped: false)

    let schemaVersion: Int
    var stepIndex: Int
    var isComplete: Bool
    var wasSkipped: Bool

    init(
        schemaVersion: Int = currentSchemaVersion,
        stepIndex: Int,
        isComplete: Bool,
        wasSkipped: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.stepIndex = stepIndex
        self.isComplete = isComplete
        self.wasSkipped = wasSkipped
    }

    var currentStep: OnboardingStep {
        let boundedIndex = min(max(stepIndex, 0), OnboardingStep.allCases.count - 1)
        return OnboardingStep.allCases[boundedIndex]
    }
}
