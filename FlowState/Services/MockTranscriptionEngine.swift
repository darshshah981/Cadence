import Foundation

final actor MockTranscriptionEngine: TranscriptionEngine {
    private var totalFrames = 0
    private var lastSampleRate = 16_000.0
    private var configuration = TranscriptionConfiguration()

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {
        self.configuration = configuration
    }

    func prepare() async throws {}

    func startSession() async throws {
        totalFrames = 0
        lastSampleRate = 16_000.0
    }

    func appendAudio(_ chunk: AudioChunk) async {
        totalFrames += chunk.frameCount
        lastSampleRate = chunk.sampleRate
    }

    func previewTranscript() async -> PreviewTranscript? {
        guard totalFrames > 0 else { return nil }
        let duration = Double(totalFrames) / max(lastSampleRate, 1)
        return PreviewTranscript(
            confirmedText: "Previewing",
            unconfirmedText: "\(String(format: "%.1f", duration))s with \(configuration.model.shortLabel)"
        )
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        let effectiveDuration = metrics.duration > 0 ? metrics.duration : Double(totalFrames) / max(lastSampleRate, 1)
        let roundedDuration = String(format: "%.1f", effectiveDuration)
        let text = "FlowState mock transcript captured \(roundedDuration) seconds of speech using \(configuration.summary)."

        return FinalTranscript(
            rawText: text,
            cleanedText: text,
            duration: effectiveDuration
        )
    }

    func cancelSession() async {
        totalFrames = 0
    }

    func statusSummary() async -> String {
        "Mock transcription backend (\(configuration.summary))"
    }
}
