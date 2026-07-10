import XCTest
@testable import Cadence

final class OnboardingTests: XCTestCase {
    func testFreshProgressStartsAtWelcomeAndCanResume() throws {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingProgressStore(defaults: defaults)

        XCTAssertEqual(store.load(), .fresh)

        let progress = OnboardingProgress(stepIndex: 4, isComplete: false, wasSkipped: false)
        try store.save(progress)

        XCTAssertEqual(store.load(), progress)
        XCTAssertEqual(store.load().currentStep, .dictation)
    }

    func testUnknownSchemaFailsClosedToFreshProgress() throws {
        let suiteName = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingProgressStore(defaults: defaults)
        let futureProgress = OnboardingProgress(
            schemaVersion: OnboardingProgress.currentSchemaVersion + 1,
            stepIndex: 7,
            isComplete: true,
            wasSkipped: false
        )
        defaults.set(try JSONEncoder().encode(futureProgress), forKey: "Cadence.onboardingProgress")

        XCTAssertEqual(store.load(), .fresh)
    }

    func testCurrentStepClampsInvalidStoredIndex() {
        let progress = OnboardingProgress(stepIndex: 999, isComplete: false, wasSkipped: false)

        XCTAssertEqual(progress.currentStep, .ready)
    }
}
