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
    private var levelContinuation: AsyncStream<Double>.Continuation?
    private var levelTask: Task<Void, Never>?

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
            let (stream, continuation) = AsyncStream.makeStream(
                of: Double.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            levelContinuation = continuation
            levelTask = Task { [weak self] in
                for await rawLevel in stream {
                    guard let self, !Task.isCancelled else { return }
                    let displayedLevel = (rawLevel * 12).rounded(.down) / 12
                    if self.level != displayedLevel {
                        self.level = displayedLevel
                    }
                }
            }
            try captureService.startCapture { [continuation] _, level in
                continuation.yield(level)
            }
            self.lease = lease
            isListening = true
            errorMessage = nil
        } catch VoiceSessionArbiterError.busy {
            errorMessage = "Finish the active recording before checking the microphone."
        } catch {
            stopLevelUpdates()
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
        stopLevelUpdates()
        if let lease {
            sessionArbiter.release(lease)
            self.lease = nil
        }
        isListening = false
        level = 0
    }

    private func stopLevelUpdates() {
        levelContinuation?.finish()
        levelContinuation = nil
        levelTask?.cancel()
        levelTask = nil
    }
}
