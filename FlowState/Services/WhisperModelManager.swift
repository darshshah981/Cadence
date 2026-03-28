import Foundation

actor WhisperModelManager {
    private let fileManager = FileManager.default

    func ensureModel(_ model: WhisperModelOption) async throws -> URL {
        let modelURL = try modelURL(for: model)
        if fileManager.fileExists(atPath: modelURL.path) {
            return modelURL
        }

        try fileManager.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let (temporaryURL, _) = try await URLSession.shared.download(from: model.downloadURL)

        if fileManager.fileExists(atPath: modelURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
            return modelURL
        }

        try fileManager.moveItem(at: temporaryURL, to: modelURL)
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
            .appendingPathComponent("FlowState", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(model.fileName, isDirectory: false)
    }

    func statusSummary(for configuration: TranscriptionConfiguration) async -> String {
        if let modelURL = try? modelURL(for: configuration.model),
           fileManager.fileExists(atPath: modelURL.path) {
            return "Local Whisper (`\(configuration.model.fileName)`, \(configuration.decodingMode.shortLabel)) ready"
        }

        return "Local Whisper will download \(configuration.model.fileName) on first use"
    }
}
