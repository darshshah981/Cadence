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

    @MainActor
    func testMicrophoneStartFailureReleasesVoiceLease() {
        let arbiter = VoiceSessionArbiter()
        let monitor = OnboardingMicrophoneMonitor(
            captureService: ThrowingAudioCaptureService(),
            sessionArbiter: arbiter
        )

        monitor.start()

        XCTAssertNil(arbiter.activeKind)
        XCTAssertFalse(monitor.isListening)
        XCTAssertNotNil(monitor.errorMessage)
    }
}

private final class ThrowingAudioCaptureService: AudioCaptureServing {
    struct StartError: Error {}

    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws {
        throw StartError()
    }

    func stopCapture() -> AudioCaptureSessionMetrics {
        AudioCaptureSessionMetrics(
            duration: 0,
            frameCount: 0,
            sampleRate: 16_000,
            speechDetected: false,
            speechFrameCount: 0,
            peakLevel: 0
        )
    }
}
