import Combine
import Foundation

@MainActor
final class OnboardingMicrophoneMonitor: ObservableObject {
    @Published private(set) var level = 0.0
    @Published private(set) var isListening = false
    @Published private(set) var errorMessage: String?

    private let captureService: AudioCaptureServing
    private let sessionArbiter: VoiceSessionArbiter
    private var lease: VoiceSessionLease?

    init(
        captureService: AudioCaptureServing = AudioCaptureService(),
        sessionArbiter: VoiceSessionArbiter
    ) {
        self.captureService = captureService
        self.sessionArbiter = sessionArbiter
    }

    func start() {
        guard !isListening else { return }
        do {
            let lease = try sessionArbiter.acquire(for: .microphoneCheck)
            try captureService.startCapture { [weak self] _, level in
                Task { @MainActor in
                    self?.level = level
                }
            }
            self.lease = lease
            isListening = true
            errorMessage = nil
        } catch VoiceSessionArbiterError.busy {
            errorMessage = "Finish the active recording before checking the microphone."
        } catch {
            if let lease {
                sessionArbiter.release(lease)
                self.lease = nil
            }
            errorMessage = "Cadence could not start the microphone check."
        }
    }

    func stop() {
        guard isListening else { return }
        _ = captureService.stopCapture()
        if let lease {
            sessionArbiter.release(lease)
            self.lease = nil
        }
        isListening = false
        level = 0
    }
}
