import Foundation
import OSLog
import whisper

private let whisperLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "Whisper"
)

#if DEBUG
private let whisperCppLogCallback: ggml_log_callback = { _, rawText, _ in
    guard let rawText else { return }

    let message = String(cString: rawText)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }

    if message.contains("loading Core ML model") {
        whisperLogger.info("whisper.cpp loading Core ML model")
    } else if message.contains("Core ML model loaded") {
        whisperLogger.info("whisper.cpp Core ML model loaded")
    } else if message.contains("failed to load Core ML") {
        whisperLogger.error("whisper.cpp failed to load Core ML model")
    } else if message.contains("whisper_print_timings") ||
        message.contains("fallbacks =") ||
        message.contains(" time =") {
        whisperLogger.info("whisper.cpp \(message, privacy: .public)")
    }
}
#endif

final actor LocalWhisperTranscriptionEngine: TranscriptionEngine {
    private static let dictationPrompt = "This is English dictation for emails, chats, notes, and documents. Prefer literal wording, correct punctuation, and paragraph breaks. Avoid hallucinations."
    private static let previewSampleCount = 96_000
    private static let whisperSampleRate = 16_000.0
    private static let audioContextFramesPerSecond = 50.0
    private static let audioContextBlockSize = 256
    private static let minimumAudioContext = 512
    private static let maximumAudioContext = 1500
    private static let maximumReducedAudioContextSamples = 72_000

    private let modelManager: WhisperModelManager
    private let previewEngine: LocalWhisperPreviewEngine
    private var context: OpaquePointer?
    private var samples = [Float]()
    private var modelURL: URL?
    private var configuration = TranscriptionConfiguration()

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
        self.previewEngine = LocalWhisperPreviewEngine(modelManager: modelManager)
#if DEBUG
        whisper_log_set(whisperCppLogCallback, nil)
#endif
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {
        self.configuration = configuration
        try await previewEngine.updateConfiguration(configuration)

        if let currentModelURL = modelURL,
           currentModelURL.lastPathComponent != configuration.model.fileName {
            if let context {
                whisper_free(context)
            }
            context = nil
            modelURL = nil
        }
    }

    func prepare() async throws {
        let resolvedModelURL = try await modelManager.ensureModel(configuration.model)

        if let currentModelURL = modelURL,
           currentModelURL.path != resolvedModelURL.path,
           let context {
            whisper_free(context)
            self.context = nil
        }

        self.modelURL = resolvedModelURL

        guard context == nil else { return }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        contextParams.flash_attn = false
        contextParams.gpu_device = 0

        let newContext = resolvedModelURL.path.withCString { pathPointer in
            whisper_init_from_file_with_params(pathPointer, contextParams)
        }

        guard let newContext else {
            throw WhisperEngineError.contextInitializationFailed
        }

        context = newContext
        try await previewEngine.prepare()
    }

    func startSession() async throws {
        guard context != nil else {
            throw WhisperEngineError.contextInitializationFailed
        }

        samples.removeAll(keepingCapacity: true)
    }

    func appendAudio(_ chunk: AudioChunk) async {
        samples.append(contentsOf: chunk.samples)
    }

    func previewTranscript() async -> PreviewTranscript? {
        guard configuration.livePreviewEnabled else {
            return nil
        }

        let previewSource = samples.count > Self.previewSampleCount
            ? Array(samples.suffix(Self.previewSampleCount))
            : samples
        let processedSamples = TranscriptionAudioPreprocessor.preprocess(previewSource, configuration: configuration)
        guard processedSamples.count >= 4_800 else { return nil }

        return await previewEngine.transcribePreview(from: processedSamples)
    }

    func finishSession(metrics: AudioCaptureSessionMetrics) async throws -> FinalTranscript {
        guard let context else {
            throw WhisperEngineError.contextInitializationFailed
        }

        guard !samples.isEmpty, metrics.speechDetected else {
            throw WhisperEngineError.emptyAudio
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
#if DEBUG
        whisper_reset_timings(context)
#endif
        let text = Self.runTranscription(
            context: context,
            samples: processedSamples,
            configuration: configuration,
            previewOnly: false
        ) ?? ""
#if DEBUG
        whisper_print_timings(context)
#endif
        let decodeElapsed = Date().timeIntervalSince(decodeStartedAt)

        guard !text.isEmpty else {
            whisperLogger.error(
                "Cadence timing whisperFinal failed audio=\(Self.formatSeconds(metrics.duration), privacy: .public)s speech=\(Self.formatSeconds(speechDuration), privacy: .public)s samples=\(inputSampleCount, privacy: .public) processed=\(processedSamples.count, privacy: .public) preprocess=\(Self.formatSeconds(preprocessElapsed), privacy: .public)s decode=\(Self.formatSeconds(decodeElapsed), privacy: .public)s"
            )
            throw WhisperEngineError.noTranscript
        }

        let cleaned = Self.normalizeWhitespace(in: text)
        samples.removeAll(keepingCapacity: true)
        whisperLogger.info(
            "Cadence timing whisperFinal audio=\(Self.formatSeconds(metrics.duration), privacy: .public)s speech=\(Self.formatSeconds(speechDuration), privacy: .public)s samples=\(inputSampleCount, privacy: .public) processed=\(processedSamples.count, privacy: .public) audioCtx=\(Self.audioContextLimit(for: processedSamples.count), privacy: .public) preprocess=\(Self.formatSeconds(preprocessElapsed), privacy: .public)s decode=\(Self.formatSeconds(decodeElapsed), privacy: .public)s total=\(Self.formatSeconds(Date().timeIntervalSince(finishStartedAt)), privacy: .public)s model=\(self.configuration.model.rawValue, privacy: .public) mode=\(self.configuration.decodingMode.rawValue, privacy: .public)"
        )

        return FinalTranscript(rawText: text, cleanedText: cleaned, duration: metrics.duration)
    }

    func cancelSession() async {
        samples.removeAll(keepingCapacity: true)
        await previewEngine.reset()
    }

    func statusSummary() async -> String {
        await modelManager.statusSummary(for: configuration)
    }

    private static func normalizeWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    fileprivate static func runTranscription(
        context: OpaquePointer,
        samples: [Float],
        configuration: TranscriptionConfiguration,
        previewOnly: Bool
    ) -> String? {
        var params = whisper_full_default_params(
            previewOnly || configuration.decodingMode == .greedy ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH
        )
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = previewOnly ? true : !configuration.keepContext
        params.no_timestamps = true
        params.single_segment = previewOnly
        params.suppress_blank = true
        params.suppress_non_speech_tokens = true
        params.detect_language = false
        params.temperature = 0
        params.temperature_inc = 0
        params.entropy_thold = 2.4
        params.logprob_thold = -1
        params.max_len = previewOnly ? 80 : 120
        params.audio_ctx = audioContextLimit(for: samples.count)
        params.split_on_word = true
        params.beam_search.beam_size = previewOnly ? 1 : (configuration.decodingMode == .beamSearch ? 5 : 1)
        params.greedy.best_of = 1
        params.length_penalty = -1
        params.n_threads = Int32(min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))

        let prompt = initialPrompt(for: configuration)
        let result: Int32 = prompt.withCString { promptPointer in
            params.initial_prompt = promptPointer
            return "en".withCString { languagePointer in
                params.language = languagePointer
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }

        guard result == 0 else {
            return nil
        }

        let segmentCount = Int(whisper_full_n_segments(context))
        return (0..<segmentCount)
            .compactMap { index -> String? in
                guard let pointer = whisper_full_get_segment_text(context, Int32(index)) else {
                    return nil
                }
                return String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func initialPrompt(for configuration: TranscriptionConfiguration) -> String {
        let vocabularyHint = VocabularyEntry.promptHint(from: configuration.vocabularyText)
        guard !vocabularyHint.isEmpty else {
            return dictationPrompt
        }

        return dictationPrompt + " Preferred spellings and terms: " + vocabularyHint + "."
    }

    fileprivate static func audioContextLimit(for sampleCount: Int) -> Int32 {
        guard sampleCount <= maximumReducedAudioContextSamples else {
            return 0
        }

        let audioSeconds = Double(sampleCount) / whisperSampleRate
        let estimatedContext = Int(ceil(audioSeconds * audioContextFramesPerSecond)) + 64
        let boundedContext = min(maximumAudioContext, max(minimumAudioContext, estimatedContext))
        let roundedContext = min(
            maximumAudioContext,
            ((boundedContext + audioContextBlockSize - 1) / audioContextBlockSize) * audioContextBlockSize
        )
        return Int32(roundedContext)
    }
}

final actor LocalWhisperPreviewEngine {
    private let modelManager: WhisperModelManager
    private var configuration = TranscriptionConfiguration()
    private var context: OpaquePointer?
    private var modelURL: URL?
    private var previousPreviewText = ""

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
    }

    deinit {
        if let context {
            whisper_free(context)
        }
    }

    func updateConfiguration(_ configuration: TranscriptionConfiguration) async throws {
        self.configuration = configuration

        let desiredModel = previewModel(for: configuration)
        if let modelURL,
           modelURL.lastPathComponent != desiredModel.fileName {
            if let context {
                whisper_free(context)
            }
            self.context = nil
            self.modelURL = nil
        }
    }

    func prepare() async throws {
        guard configuration.livePreviewEnabled else { return }

        let previewModel = previewModel(for: configuration)
        let resolvedModelURL = try await modelManager.ensureModel(previewModel)

        if let currentModelURL = modelURL,
           currentModelURL.path != resolvedModelURL.path,
           let context {
            whisper_free(context)
            self.context = nil
        }

        self.modelURL = resolvedModelURL

        guard context == nil else { return }

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true
        contextParams.flash_attn = false
        contextParams.gpu_device = 0

        let newContext = resolvedModelURL.path.withCString { pathPointer in
            whisper_init_from_file_with_params(pathPointer, contextParams)
        }

        guard let newContext else {
            throw WhisperEngineError.contextInitializationFailed
        }

        context = newContext
    }

    func transcribePreview(from samples: [Float]) async -> PreviewTranscript? {
        guard configuration.livePreviewEnabled else { return nil }

        if context == nil {
            try? await prepare()
        }
        guard let context else { return nil }

        let startedAt = Date()
        guard let previewText = LocalWhisperTranscriptionEngine.runTranscription(
            context: context,
            samples: samples,
            configuration: configuration,
            previewOnly: true
        ), !previewText.isEmpty else {
            return nil
        }
        whisperLogger.debug(
            "Cadence timing whisperPreview samples=\(samples.count, privacy: .public) audioCtx=\(LocalWhisperTranscriptionEngine.audioContextLimit(for: samples.count), privacy: .public) decode=\(LocalWhisperTranscriptionEngine.formatSeconds(Date().timeIntervalSince(startedAt)), privacy: .public)s model=\(self.previewModel(for: self.configuration).rawValue, privacy: .public)"
        )

        let preview = Self.makePreview(previous: previousPreviewText, current: previewText)
        previousPreviewText = previewText
        return preview
    }

    func reset() async {
        previousPreviewText = ""
    }

    private func previewModel(for configuration: TranscriptionConfiguration) -> WhisperModelOption {
        switch configuration.model {
        case .tinyEnglish, .baseEnglish:
            return configuration.model
        case .smallEnglish, .mediumEnglish, .largeV3:
            return .tinyEnglish
        }
    }

    private static func makePreview(previous: String, current: String) -> PreviewTranscript {
        let previousWords = previous.split(separator: " ").map(String.init)
        let currentWords = current.split(separator: " ").map(String.init)

        var prefixCount = 0
        while prefixCount < previousWords.count,
              prefixCount < currentWords.count,
              previousWords[prefixCount].caseInsensitiveCompare(currentWords[prefixCount]) == .orderedSame {
            prefixCount += 1
        }

        return PreviewTranscript(
            confirmedText: currentWords.prefix(prefixCount).joined(separator: " "),
            unconfirmedText: currentWords.dropFirst(prefixCount).joined(separator: " ")
        )
    }
}

enum WhisperEngineError: LocalizedError {
    case contextInitializationFailed
    case emptyAudio
    case noTranscript
    case transcriptionFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .contextInitializationFailed:
            return "Cadence could not initialize the local Whisper model."
        case .emptyAudio:
            return "No speech audio was captured."
        case .noTranscript:
            return "Whisper did not return any transcript text."
        case .transcriptionFailed(let code):
            return "Local Whisper transcription failed with code \(code)."
        }
    }
}
