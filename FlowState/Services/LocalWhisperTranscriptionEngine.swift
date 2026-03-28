import Foundation
import whisper

final actor LocalWhisperTranscriptionEngine: TranscriptionEngine {
    private static let dictationPrompt = "This is English dictation for emails, chats, notes, and documents. Prefer literal wording, correct punctuation, and paragraph breaks. Avoid hallucinations."
    private static let silenceWindowSize = 160
    private static let silenceThreshold: Float = 0.008
    private static let trimPaddingSamples = 2_400
    private static let previewSampleCount = 96_000

    private let modelManager: WhisperModelManager
    private let previewEngine: LocalWhisperPreviewEngine
    private var context: OpaquePointer?
    private var samples = [Float]()
    private var modelURL: URL?
    private var configuration = TranscriptionConfiguration()

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
        self.previewEngine = LocalWhisperPreviewEngine(modelManager: modelManager)
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
        let processedSamples = Self.preprocess(previewSource, configuration: configuration)
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

        let processedSamples = Self.preprocess(samples, configuration: configuration)
        guard !processedSamples.isEmpty else {
            throw WhisperEngineError.emptyAudio
        }

        let text = Self.runTranscription(
            context: context,
            samples: processedSamples,
            configuration: configuration,
            previewOnly: false
        ) ?? ""

        guard !text.isEmpty else {
            throw WhisperEngineError.noTranscript
        }

        let cleaned = Self.normalizeWhitespace(in: text)
        samples.removeAll(keepingCapacity: true)

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

    private static func preprocess(_ samples: [Float], configuration: TranscriptionConfiguration) -> [Float] {
        var processed = samples

        if configuration.trimSilence {
            processed = trimSilence(in: processed)
        }

        if configuration.normalizeAudio {
            processed = normalizeAudio(processed)
        }

        return processed
    }

    private static func trimSilence(in samples: [Float]) -> [Float] {
        guard samples.count > silenceWindowSize else { return samples }

        let amplitudes = samples.map { abs($0) }
        var startIndex = 0
        var endIndex = samples.count

        var leadingWindowSum: Float = amplitudes.prefix(silenceWindowSize).reduce(0, +)
        var index = 0
        while index + silenceWindowSize <= amplitudes.count {
            let average = leadingWindowSum / Float(silenceWindowSize)
            if average >= silenceThreshold {
                startIndex = max(0, index - trimPaddingSamples)
                break
            }

            let outgoing = amplitudes[index]
            let incomingIndex = index + silenceWindowSize
            if incomingIndex < amplitudes.count {
                leadingWindowSum += amplitudes[incomingIndex] - outgoing
            }
            index += 1
            startIndex = samples.count
        }

        guard startIndex < samples.count else {
            return samples
        }

        var trailingWindowSum: Float = amplitudes.suffix(silenceWindowSize).reduce(0, +)
        index = amplitudes.count - silenceWindowSize
        while index >= 0 {
            let average = trailingWindowSum / Float(silenceWindowSize)
            if average >= silenceThreshold {
                endIndex = min(samples.count, index + silenceWindowSize + trimPaddingSamples)
                break
            }

            if index > 0 {
                trailingWindowSum += amplitudes[index - 1] - amplitudes[index + silenceWindowSize - 1]
            }
            index -= 1
            endIndex = 0
        }

        guard endIndex > startIndex else {
            return samples
        }

        return Array(samples[startIndex..<endIndex])
    }

    private static func normalizeAudio(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0.0001 else {
            return samples
        }

        let targetPeak: Float = 0.85
        let gain = min(targetPeak / peak, 8)
        guard gain > 1.05 else { return samples }

        return samples.map { sample in
            max(-1, min(1, sample * gain))
        }
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

        guard let previewText = LocalWhisperTranscriptionEngine.runTranscription(
            context: context,
            samples: samples,
            configuration: configuration,
            previewOnly: true
        ), !previewText.isEmpty else {
            return nil
        }

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
        case .smallEnglish, .mediumEnglish:
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
            return "FlowState could not initialize the local Whisper model."
        case .emptyAudio:
            return "No speech audio was captured."
        case .noTranscript:
            return "Whisper did not return any transcript text."
        case .transcriptionFailed(let code):
            return "Local Whisper transcription failed with code \(code)."
        }
    }
}
