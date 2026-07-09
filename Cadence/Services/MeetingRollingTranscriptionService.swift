import Foundation

enum MeetingTranscriptionFinalizationResult: Equatable, Sendable {
    case completed([TranscriptSegment])
    case failed(String)
    case timedOut
}

enum MeetingTranscriptionFinalizer {
    static func finish(
        service: MeetingRollingTranscriptionService,
        timeout: Duration
    ) async -> MeetingTranscriptionFinalizationResult {
        await withCheckedContinuation { continuation in
            let gate = MeetingTranscriptionFinalizationGate()
            let finalizeTask = Task {
                do {
                    let segments = try await service.finish()
                    gate.resume(continuation, with: .completed(segments))
                } catch {
                    gate.resume(continuation, with: .failed(error.localizedDescription))
                }
            }

            Task {
                try? await Task.sleep(for: timeout)
                finalizeTask.cancel()
                gate.resume(continuation, with: .timedOut)
            }
        }
    }
}

private final class MeetingTranscriptionFinalizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<MeetingTranscriptionFinalizationResult, Never>,
        with result: MeetingTranscriptionFinalizationResult
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}

actor MeetingRollingTranscriptionService {
    private let engine: TranscriptionEngine
    private let windowDuration: TimeInterval

    private var active = false
    private var bufferedFrameCount = 0
    private var bufferedSpeechFrameCount = 0
    private var sampleRate = 16_000.0
    private var peakLevel = 0.0
    private var segmentStartTime: TimeInterval = 0
    private var elapsedAudioTime: TimeInterval = 0
    private var operationTail = Task<Void, Never> {}

    init(engine: TranscriptionEngine, windowDuration: TimeInterval = 30) {
        self.engine = engine
        self.windowDuration = windowDuration
    }

    func start(configuration: TranscriptionConfiguration) async throws {
        operationTail = Task<Void, Never> {}
        try await engine.updateConfiguration(configuration)
        try await engine.startSession()
        active = true
        bufferedFrameCount = 0
        bufferedSpeechFrameCount = 0
        sampleRate = 16_000
        peakLevel = 0
        segmentStartTime = 0
        elapsedAudioTime = 0
    }

    func append(_ chunk: AudioChunk, level: Double) async throws -> [TranscriptSegment] {
        try await enqueueOperation { [self, chunk, level] in
            try await self.performAppend(chunk, level: level)
        }
    }

    func finish() async throws -> [TranscriptSegment] {
        try await enqueueOperation { [self] in
            try await self.performFinish()
        }
    }

    func cancel() async {
        operationTail = Task<Void, Never> {}
        active = false
        bufferedFrameCount = 0
        bufferedSpeechFrameCount = 0
        peakLevel = 0
        await engine.cancelSession()
    }

    private func enqueueOperation<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previousOperation = operationTail
        let nextOperation = Task { () throws -> T in
            await previousOperation.value
            return try await operation()
        }
        operationTail = Task {
            _ = try? await nextOperation.value
        }
        return try await nextOperation.value
    }

    private func performAppend(_ chunk: AudioChunk, level: Double) async throws -> [TranscriptSegment] {
        guard active else { return [] }

        var emittedSegments = [TranscriptSegment]()
        let frameCount = min(chunk.frameCount, chunk.samples.count)
        var frameOffset = 0

        while frameOffset < frameCount {
            let remainingWindowFrames = max(Int(((windowDuration - currentWindowDuration) * chunk.sampleRate).rounded(.down)), 1)
            let framesToAppend = min(remainingWindowFrames, frameCount - frameOffset)
            let sampleEnd = frameOffset + framesToAppend
            let subchunk = AudioChunk(
                samples: Array(chunk.samples[frameOffset..<sampleEnd]),
                frameCount: framesToAppend,
                sampleRate: chunk.sampleRate
            )

            await appendToCurrentWindow(subchunk, level: level)
            frameOffset = sampleEnd

            if currentWindowDuration >= windowDuration {
                if let segment = try await finishCurrentWindow(startsNextSession: true) {
                    emittedSegments.append(segment)
                }
            }
        }

        return emittedSegments
    }

    private func performFinish() async throws -> [TranscriptSegment] {
        guard active else { return [] }
        defer { active = false }
        guard let segment = try await finishCurrentWindow(startsNextSession: false) else {
            return []
        }
        return [segment]
    }

    private var currentWindowDuration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(bufferedFrameCount) / sampleRate
    }

    private func appendToCurrentWindow(_ chunk: AudioChunk, level: Double) async {
        await engine.appendAudio(chunk)
        bufferedFrameCount += chunk.frameCount
        sampleRate = chunk.sampleRate
        peakLevel = max(peakLevel, level)
        if level > 0.008 {
            bufferedSpeechFrameCount += chunk.frameCount
        }
    }

    private func finishCurrentWindow(startsNextSession: Bool) async throws -> TranscriptSegment? {
        guard bufferedFrameCount > 0 else {
            if startsNextSession {
                try await engine.startSession()
            }
            return nil
        }

        let duration = currentWindowDuration
        let segmentEndTime = segmentStartTime + duration
        let metrics = AudioCaptureSessionMetrics(
            duration: duration,
            frameCount: bufferedFrameCount,
            sampleRate: sampleRate,
            speechDetected: bufferedFrameCount > 0,
            speechFrameCount: max(bufferedSpeechFrameCount, bufferedFrameCount),
            peakLevel: peakLevel
        )

        let transcript: FinalTranscript
        do {
            transcript = try await engine.finishSession(metrics: metrics)
        } catch {
            resetWindow(endingAt: segmentEndTime)
            if startsNextSession {
                try await engine.startSession()
            }
            guard Self.isEmptyTranscriptError(error) else {
                throw error
            }
            return nil
        }

        resetWindow(endingAt: segmentEndTime)
        if startsNextSession {
            try await engine.startSession()
        }

        let cleanedText = transcript.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedText.isEmpty else { return nil }
        return TranscriptSegment(
            text: cleanedText,
            startTime: segmentStartTime - duration,
            endTime: segmentEndTime
        )
    }

    private func resetWindow(endingAt segmentEndTime: TimeInterval) {
        bufferedFrameCount = 0
        bufferedSpeechFrameCount = 0
        peakLevel = 0
        elapsedAudioTime = segmentEndTime
        segmentStartTime = segmentEndTime
    }

    private static func isEmptyTranscriptError(_ error: Error) -> Bool {
        switch error {
        case WhisperEngineError.emptyAudio, WhisperEngineError.noTranscript:
            return true
        default:
            return false
        }
    }
}
