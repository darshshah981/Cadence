import Foundation

final actor SwitchingTranscriptionEngine: TranscriptionEngine {
    private let whisperKitEngine: TranscriptionEngine
    private let whisperCppEngine: TranscriptionEngine
    private var activeBackend: TranscriptionBackendOption = .whisperKit

    init(
        whisperKitEngine: TranscriptionEngine,
        whisperCppEngine: TranscriptionEngine
    ) {
        self.whisperKitEngine = whisperKitEngine
        self.whisperCppEngine = whisperCppEngine
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {
        if configuration.backend != activeBackend {
            await activeEngine.cancelSession()
            activeBackend = configuration.backend
        }

        try await activeEngine.updateConfiguration(configuration)
    }

    func prepare() async throws {
        try await activeEngine.prepare()
    }

    func startSession() async throws {
        try await activeEngine.startSession()
    }

    func appendAudio(_ chunk: AudioChunk) async {
        await activeEngine.appendAudio(chunk)
    }

    func previewTranscript() async -> PreviewTranscript? {
        await activeEngine.previewTranscript()
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        try await activeEngine.finishSession(metrics: metrics)
    }

    func cancelSession() async {
        await activeEngine.cancelSession()
    }

    func statusSummary() async -> String {
        await activeEngine.statusSummary()
    }

    private var activeEngine: TranscriptionEngine {
        switch activeBackend {
        case .whisperKit:
            return whisperKitEngine
        case .whisperCpp:
            return whisperCppEngine
        }
    }
}
