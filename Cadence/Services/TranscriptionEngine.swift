import Foundation

protocol TranscriptionEngine: AnyObject {
    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws
    func prepare() async throws
    func startSession() async throws
    func appendAudio(_ chunk: AudioChunk) async
    func previewTranscript() async -> PreviewTranscript?
    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript
    func cancelSession() async
    func statusSummary() async -> String
}

enum WhisperEngineError: LocalizedError {
    case contextInitializationFailed
    case emptyAudio
    case noTranscript

    var errorDescription: String? {
        switch self {
        case .contextInitializationFailed:
            return "Cadence could not initialize the transcription model."
        case .emptyAudio:
            return "No speech audio was captured."
        case .noTranscript:
            return "Whisper did not return any transcript text."
        }
    }
}
