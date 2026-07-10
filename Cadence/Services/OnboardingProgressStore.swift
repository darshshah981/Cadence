import Foundation
import OSLog

private let onboardingStoreLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Onboarding"
)

final class OnboardingProgressStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "Cadence.onboardingProgress") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> OnboardingProgress {
        guard let data = defaults.data(forKey: key) else { return .fresh }
        guard let progress = try? JSONDecoder().decode(OnboardingProgress.self, from: data),
              progress.schemaVersion == OnboardingProgress.currentSchemaVersion else {
            onboardingStoreLogger.error("Onboarding progress could not be loaded")
            return .fresh
        }
        return progress
    }

    func save(_ progress: OnboardingProgress) throws {
        defaults.set(try JSONEncoder().encode(progress), forKey: key)
    }
}
