import Foundation
import OSLog
@preconcurrency import WhisperKit

private let whisperKitLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "WhisperKit"
)

final actor WhisperKitTranscriptionEngine: TranscriptionEngine {
    private static let modelStoreDirectoryName = "WhisperKit"
    private static let fastTokenLimit = 192

    private var configuration = TranscriptionConfiguration()
    private var pipeline: WhisperKit?
    private var loadedModelName: String?
    private var prepareTask: Task<WhisperKit, Error>?
    private var preparingModelName: String?
    private var samples = [Float]()

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {
        let nextModelName = Self.modelName(for: configuration.model)
        if loadedModelName != nil, loadedModelName != nextModelName {
            pipeline = nil
            loadedModelName = nil
        }

        if let preparingModelName, preparingModelName != nextModelName {
            prepareTask?.cancel()
            prepareTask = nil
            self.preparingModelName = nil
        }

        self.configuration = configuration
    }

    func prepare() async throws {
        let modelName = Self.modelName(for: configuration.model)
        if pipeline != nil, loadedModelName == modelName {
            return
        }

        if let prepareTask, preparingModelName == modelName {
            pipeline = try await prepareTask.value
            loadedModelName = modelName
            return
        }

        let startedAt = Date()
        let downloadBase = try Self.modelStoreDirectory()
        whisperKitLogger.info(
            "Cadence timing whisperKitPrepare start model=\(modelName, privacy: .public) store=\(downloadBase.path, privacy: .public)"
        )
        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            computeOptions: ModelComputeOptions(),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true,
            useBackgroundDownloadSession: false
        )

        let task = Task {
            let newPipeline: WhisperKit
            do {
                newPipeline = try await WhisperKit(config)
            } catch {
                whisperKitLogger.error(
                    "Cadence timing whisperKitPrepare failed model=\(modelName, privacy: .public) elapsed=\(Self.formatSeconds(Date().timeIntervalSince(startedAt)), privacy: .public)s error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }

            whisperKitLogger.info(
                "Cadence timing whisperKitPrepare model=\(modelName, privacy: .public) elapsed=\(Self.formatSeconds(Date().timeIntervalSince(startedAt)), privacy: .public)s folder=\(newPipeline.modelFolder?.path ?? "unknown", privacy: .public)"
            )
            return newPipeline
        }

        prepareTask = task
        preparingModelName = modelName
        defer {
            if preparingModelName == modelName {
                prepareTask = nil
                preparingModelName = nil
            }
        }

        do {
            let newPipeline = try await task.value
            pipeline = newPipeline
            loadedModelName = modelName
        } catch {
            throw error
        }
    }

    func startSession() async throws {
        if pipeline == nil {
            try await prepare()
        }

        samples.removeAll(keepingCapacity: true)
    }

    func appendAudio(_ chunk: AudioChunk) async {
        samples.append(contentsOf: chunk.samples)
    }

    func previewTranscript() async -> PreviewTranscript? {
        nil
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        guard !samples.isEmpty, metrics.speechDetected else {
            throw WhisperEngineError.emptyAudio
        }

        if pipeline == nil {
            try await prepare()
        }

        guard let pipeline else {
            throw WhisperEngineError.contextInitializationFailed
        }

        let finishStartedAt = Date()
        let inputSampleCount = samples.count
        let speechDuration = metrics.sampleRate > 0
            ? Double(metrics.speechFrameCount) / metrics.sampleRate
            : metrics.duration

        let preprocessStartedAt = Date()
        let processedSamples = TranscriptionAudioPreprocessor.preprocess(samples, configuration: configuration)
        let preprocessElapsed = Date().timeIntervalSince(preprocessStartedAt)
        guard !processedSamples.isEmpty else {
            throw WhisperEngineError.emptyAudio
        }

        let decodeStartedAt = Date()
        let options = decodeOptions(for: configuration)
        let results = try await pipeline.transcribe(
            audioArray: processedSamples,
            decodeOptions: options
        )
        let decodeElapsed = Date().timeIntervalSince(decodeStartedAt)

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            whisperKitLogger.error(
                "Cadence timing whisperKitFinal failed audio=\(Self.formatSeconds(metrics.duration), privacy: .public)s speech=\(Self.formatSeconds(speechDuration), privacy: .public)s samples=\(inputSampleCount, privacy: .public) processed=\(processedSamples.count, privacy: .public) preprocess=\(Self.formatSeconds(preprocessElapsed), privacy: .public)s decode=\(Self.formatSeconds(decodeElapsed), privacy: .public)s"
            )
            throw WhisperEngineError.noTranscript
        }

        let cleaned = Self.normalizeWhitespace(in: text)
        samples.removeAll(keepingCapacity: true)
        whisperKitLogger.info(
            "Cadence timing whisperKitFinal audio=\(Self.formatSeconds(metrics.duration), privacy: .public)s speech=\(Self.formatSeconds(speechDuration), privacy: .public)s samples=\(inputSampleCount, privacy: .public) processed=\(processedSamples.count, privacy: .public) preprocess=\(Self.formatSeconds(preprocessElapsed), privacy: .public)s decode=\(Self.formatSeconds(decodeElapsed), privacy: .public)s total=\(Self.formatSeconds(Date().timeIntervalSince(finishStartedAt)), privacy: .public)s model=\(Self.modelName(for: self.configuration.model), privacy: .public) mode=\(self.configuration.decodingMode.rawValue, privacy: .public)"
        )

        return FinalTranscript(rawText: text, cleanedText: cleaned, duration: metrics.duration)
    }

    func cancelSession() async {
        samples.removeAll(keepingCapacity: true)
    }

    func statusSummary() async -> String {
        let modelName = Self.modelName(for: configuration.model)
        if let pipeline {
            return "WhisperKit \(Self.displayModelName(for: configuration.model)) \(pipeline.modelState.description.lowercased())"
        }

        return "WhisperKit \(Self.displayModelName(for: configuration.model)) ready to load (\(modelName))"
    }

    private func decodeOptions(for configuration: TranscriptionConfiguration) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: "en",
            temperature: 0,
            temperatureIncrementOnFallback: configuration.decodingMode == .beamSearch ? 0.2 : 0,
            temperatureFallbackCount: configuration.decodingMode == .beamSearch ? 2 : 0,
            sampleLength: Self.fastTokenLimit,
            topK: configuration.decodingMode == .beamSearch ? 5 : 1,
            usePrefillPrompt: true,
            usePrefillCache: true,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false,
            suppressBlank: true,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: 2,
            chunkingStrategy: .vad
        )
    }

    private static func modelName(for model: WhisperModelOption) -> String {
        switch model {
        case .tinyEnglish:
            return "openai_whisper-tiny.en"
        case .baseEnglish:
            return "openai_whisper-base.en"
        case .smallEnglish:
            return "openai_whisper-small.en"
        case .mediumEnglish:
            return "openai_whisper-small.en"
        case .largeV3:
            return "openai_whisper-large-v3-v20240930_626MB"
        }
    }

    private static func displayModelName(for model: WhisperModelOption) -> String {
        switch model {
        case .mediumEnglish:
            return "small.en"
        case .largeV3:
            return "large-v3"
        default:
            return model.shortLabel
        }
    }

    private static func modelStoreDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent(modelStoreDirectoryName, isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }
}
