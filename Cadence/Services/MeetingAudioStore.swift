import AVFoundation
import Foundation

enum MeetingAudioStoreError: LocalizedError {
    case missingRecording(String)
    case unsupportedAudioFormat

    var errorDescription: String? {
        switch self {
        case .missingRecording:
            return "Cadence could not find the saved meeting audio."
        case .unsupportedAudioFormat:
            return "Cadence could not read the saved meeting audio."
        }
    }
}

final class MeetingAudioStore {
    private static let sampleRate = 16_000.0

    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.directoryURL = try directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        try fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    func makeRecorder(
        noteID: UUID,
        recordingID: UUID,
        source: MeetingCaptureSource
    ) throws -> MeetingAudioRecorder {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileName = Self.recordingFileName(noteID: noteID, recordingID: recordingID)
        let fileURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        return try MeetingAudioRecorder(
            fileURL: fileURL,
            fileName: fileName,
            recordingID: recordingID,
            source: source
        )
    }

    static func recordingFileName(noteID: UUID, recordingID: UUID) -> String {
        "\(noteID.uuidString)-\(recordingID.uuidString).caf"
    }

    func fileURL(for recording: MeetingAudioRecordingMetadata) -> URL {
        directoryURL.appendingPathComponent(recording.fileName, isDirectory: false)
    }

    func hasUsableAudio(for recording: MeetingAudioRecordingMetadata) -> Bool {
        hasUsableAudio(fileName: recording.fileName)
    }

    func hasUsableAudio(for orphan: OrphanedMeetingRecording) -> Bool {
        hasUsableAudio(fileName: orphan.fileName)
    }

    private func hasUsableAudio(fileName: String) -> Bool {
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return false }
        return audioFile.length > 0
    }

    /// Lists saved meeting-audio files that no note references — the launch-time
    /// orphan sweep. Never deletes; callers decide keep/discard.
    func orphanedRecordingDescriptors(referencedBy notes: [MeetingNote]) -> [OrphanedMeetingRecording] {
        let referenced = Set(notes.flatMap { $0.effectiveAudioRecordings.map(\.fileName) })
        guard let fileURLs = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return [] }
        return fileURLs.compactMap { fileURL -> OrphanedMeetingRecording? in
            guard fileURL.pathExtension == "caf", !fileURL.hasDirectoryPath else { return nil }
            let fileName = fileURL.lastPathComponent
            if referenced.contains(fileName) { return nil }
            return Self.parseRecordingFileName(fileName)
        }
    }

    @discardableResult
    func discardOrphanedRecording(_ orphan: OrphanedMeetingRecording) -> Bool {
        let url = directoryURL.appendingPathComponent(orphan.fileName, isDirectory: false)
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            return false
        }
    }

    /// Parses a `<noteID>-<recordingID>.caf` filename into its identifiers.
    /// UUID strings are 36 characters, so the stem is exactly 73 characters
    /// (36 + "-" + 36); positions are fixed rather than split on "-".
    static func parseRecordingFileName(_ fileName: String) -> OrphanedMeetingRecording? {
        let stem = (fileName as NSString).deletingPathExtension
        guard stem.count == 73 else { return nil }
        let noteIDString = String(stem.prefix(36))
        let recordingIDString = String(stem.suffix(36))
        let hyphenIndex = stem.index(stem.startIndex, offsetBy: 36)
        guard stem[hyphenIndex] == "-",
              let noteID = UUID(uuidString: noteIDString),
              let recordingID = UUID(uuidString: recordingIDString) else {
            return nil
        }
        return OrphanedMeetingRecording(recordingID: recordingID, noteID: noteID, fileName: fileName)
    }

    func deleteRecordings(for note: MeetingNote) {
        for recording in note.effectiveAudioRecordings {
            try? fileManager.removeItem(at: fileURL(for: recording))
        }
    }

    private static func defaultDirectoryURL(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return applicationSupport
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("MeetingAudio", isDirectory: true)
    }

    static func makePCMFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }
}

actor MeetingAudioRecorder {
    private let fileURL: URL
    private let fileName: String
    private let recordingID: UUID
    private let source: MeetingCaptureSource
    private let createdAt: Date
    private let format: AVAudioFormat
    private var audioFile: AVAudioFile?
    private var frameCount = 0
    private var speechFrameCount = 0
    private var speechDetected = false
    private var peakLevel = 0.0
    private var didFinish = false

    init(
        fileURL: URL,
        fileName: String,
        recordingID: UUID,
        source: MeetingCaptureSource,
        createdAt: Date = Date()
    ) throws {
        self.fileURL = fileURL
        self.fileName = fileName
        self.recordingID = recordingID
        self.source = source
        self.createdAt = createdAt
        self.format = MeetingAudioStore.makePCMFormat()
        self.audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
    }

    func append(_ chunk: AudioChunk, level: Double) throws {
        guard !didFinish, let audioFile else { return }
        let frameCount = min(chunk.frameCount, chunk.samples.count)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channelData = buffer.floatChannelData?[0] else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        chunk.samples.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return }
            channelData.update(from: baseAddress, count: frameCount)
        }
        try audioFile.write(from: buffer)

        self.frameCount += frameCount
        peakLevel = max(peakLevel, level)
        if level > 0.008 {
            speechDetected = true
            speechFrameCount += frameCount
        }
    }

    func finish(fallbackMetrics: AudioCaptureSessionMetrics?) -> MeetingAudioRecordingMetadata {
        didFinish = true
        audioFile = nil
        return makeMetadata(fallbackMetrics: fallbackMetrics)
    }

    /// Closes a recorder after capture startup failed. Any frames already written
    /// remain durable and are returned as recoverable metadata. Only a zero-frame
    /// file is removed, allowing its ledger entry to be removed atomically by the
    /// caller without losing captured audio.
    func finishAfterCaptureStartFailure() -> MeetingAudioRecordingMetadata? {
        didFinish = true
        audioFile = nil
        guard frameCount > 0 else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        var metadata = makeMetadata(fallbackMetrics: nil)
        metadata.state = .finalizationFailed
        return metadata
    }

    private func makeMetadata(fallbackMetrics: AudioCaptureSessionMetrics?) -> MeetingAudioRecordingMetadata {
        let metrics = mergedMetrics(fallbackMetrics)
        return MeetingAudioRecordingMetadata(
            id: recordingID,
            fileName: fileName,
            source: source,
            createdAt: createdAt,
            duration: metrics.duration,
            frameCount: metrics.frameCount,
            sampleRate: metrics.sampleRate,
            speechDetected: metrics.speechDetected,
            speechFrameCount: metrics.speechFrameCount,
            peakLevel: metrics.peakLevel
        )
    }

    private func mergedMetrics(_ fallbackMetrics: AudioCaptureSessionMetrics?) -> AudioCaptureSessionMetrics {
        let recordedDuration = Double(frameCount) / max(format.sampleRate, 1)
        guard let fallbackMetrics else {
            return AudioCaptureSessionMetrics(
                duration: recordedDuration,
                frameCount: frameCount,
                sampleRate: format.sampleRate,
                speechDetected: speechDetected || frameCount > 0,
                speechFrameCount: max(speechFrameCount, frameCount),
                peakLevel: peakLevel
            )
        }

        return AudioCaptureSessionMetrics(
            duration: max(fallbackMetrics.duration, recordedDuration),
            frameCount: max(fallbackMetrics.frameCount, frameCount),
            sampleRate: format.sampleRate,
            speechDetected: fallbackMetrics.speechDetected || speechDetected || frameCount > 0,
            speechFrameCount: max(fallbackMetrics.speechFrameCount, max(speechFrameCount, frameCount)),
            peakLevel: max(fallbackMetrics.peakLevel, peakLevel)
        )
    }
}
