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
