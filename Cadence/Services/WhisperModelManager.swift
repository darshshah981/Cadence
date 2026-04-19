import Foundation

actor WhisperModelManager {
    private let fileManager = FileManager.default

    func ensureModel(_ model: WhisperModelOption) async throws -> URL {
        let modelURL = try modelURL(for: model)
        if fileManager.fileExists(atPath: modelURL.path) {
            try? await ensureCoreMLEncoder(for: model, beside: modelURL)
            return modelURL
        }

        try fileManager.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let (temporaryURL, _) = try await URLSession.shared.download(from: model.downloadURL)

        if fileManager.fileExists(atPath: modelURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
            return modelURL
        }

        try fileManager.moveItem(at: temporaryURL, to: modelURL)
        try? await ensureCoreMLEncoder(for: model, beside: modelURL)
        return modelURL
    }

    func modelURL(for model: WhisperModelOption) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return appSupport
            .appendingPathComponent("Cadence", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(model.fileName, isDirectory: false)
    }

    func statusSummary(for configuration: TranscriptionConfiguration) async -> String {
        if let modelURL = try? modelURL(for: configuration.model),
           fileManager.fileExists(atPath: modelURL.path) {
            let accelerator = fileManager.fileExists(atPath: coreMLEncoderURL(for: configuration.model, beside: modelURL).path)
                ? "Core ML"
                : "CPU"
            return "Local Whisper (`\(configuration.model.fileName)`, \(configuration.decodingMode.shortLabel), \(accelerator)) ready"
        }

        return "Local Whisper will download \(configuration.model.fileName) on first use"
    }

    private func ensureCoreMLEncoder(for model: WhisperModelOption, beside modelURL: URL) async throws {
        let encoderURL = coreMLEncoderURL(for: model, beside: modelURL)
        if fileManager.fileExists(atPath: encoderURL.path) {
            return
        }

        let modelsDirectory = modelURL.deletingLastPathComponent()
        let (archiveURL, _) = try await URLSession.shared.download(from: model.coreMLEncoderArchiveURL)
        let temporaryArchiveURL = modelsDirectory.appendingPathComponent("\(model.coreMLEncoderFileName).zip", isDirectory: false)

        if fileManager.fileExists(atPath: temporaryArchiveURL.path) {
            try fileManager.removeItem(at: temporaryArchiveURL)
        }

        try fileManager.moveItem(at: archiveURL, to: temporaryArchiveURL)
        defer { try? fileManager.removeItem(at: temporaryArchiveURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", temporaryArchiveURL.path, modelsDirectory.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: encoderURL.path) else {
            throw WhisperModelManagerError.coreMLExtractionFailed
        }
    }

    private func coreMLEncoderURL(for model: WhisperModelOption, beside modelURL: URL) -> URL {
        modelURL
            .deletingLastPathComponent()
            .appendingPathComponent(model.coreMLEncoderFileName, isDirectory: true)
    }
}

enum WhisperModelManagerError: LocalizedError {
    case coreMLExtractionFailed

    var errorDescription: String? {
        switch self {
        case .coreMLExtractionFailed:
            return "Cadence could not install the Core ML Whisper accelerator."
        }
    }
}
