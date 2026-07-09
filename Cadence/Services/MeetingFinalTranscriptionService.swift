import AVFoundation
import Foundation

final class MeetingFinalTranscriptionService {
    private let audioStore: MeetingAudioStore
    private let makeEngine: () -> TranscriptionEngine
    private let readChunkFrames: AVAudioFrameCount

    init(
        audioStore: MeetingAudioStore,
        makeEngine: @escaping () -> TranscriptionEngine = { WhisperKitTranscriptionEngine() },
        readChunkFrames: AVAudioFrameCount = 16_000 * 30
    ) {
        self.audioStore = audioStore
        self.makeEngine = makeEngine
        self.readChunkFrames = readChunkFrames
    }

    func transcribe(
        recording: MeetingAudioRecordingMetadata,
        configuration: TranscriptionConfiguration
    ) async throws -> [TranscriptSegment] {
        let fileURL = audioStore.fileURL(for: recording)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MeetingAudioStoreError.missingRecording(recording.fileName)
        }

        let engine = makeEngine()
        try await engine.updateConfiguration(configuration)
        try await engine.startSession()

        let metrics = try await appendRecordingAudio(
            fileURL: fileURL,
            recording: recording,
            engine: engine
        )

        let transcript = try await engine.finishSession(metrics: metrics)
        let text = transcript.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        return [
            TranscriptSegment(
                text: text,
                startTime: 0,
                endTime: metrics.duration,
                speaker: speaker(for: recording.source),
                captureSource: recording.source,
                origin: .final,
                recordingID: recording.id
            )
        ]
    }

    private func appendRecordingAudio(
        fileURL: URL,
        recording: MeetingAudioRecordingMetadata,
        engine: TranscriptionEngine
    ) async throws -> AudioCaptureSessionMetrics {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.processingFormat

        var totalFrames = 0
        while audioFile.framePosition < audioFile.length {
            let remainingFrames = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
            let framesToRead = min(readChunkFrames, remainingFrames)
            guard framesToRead > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                break
            }

            try audioFile.read(into: buffer, frameCount: framesToRead)
            guard let channelData = buffer.floatChannelData?[0] else {
                throw MeetingAudioStoreError.unsupportedAudioFormat
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { continue }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            await engine.appendAudio(AudioChunk(samples: samples, frameCount: frameLength, sampleRate: format.sampleRate))
            totalFrames += frameLength
        }

        let duration = Double(totalFrames) / max(format.sampleRate, 1)
        return AudioCaptureSessionMetrics(
            duration: max(recording.duration, duration),
            frameCount: max(recording.frameCount, totalFrames),
            sampleRate: format.sampleRate,
            speechDetected: recording.speechDetected || totalFrames > 0,
            speechFrameCount: max(recording.speechFrameCount, totalFrames),
            peakLevel: recording.peakLevel
        )
    }

    private func speaker(for source: MeetingCaptureSource) -> TranscriptSpeaker {
        switch source {
        case .systemAudio:
            return .systemAudio
        case .microphone:
            return .user
        case .microphoneAndSystemAudio:
            return .mixedAudio
        }
    }
}
