import Foundation
import OSLog

private let composeOCRLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ComposeOCR"
)

/// Recognition is local-only. Implementations may not persist images or OCR
/// text, contact a network service, or log recognized content.
protocol ComposeScreenOCRRecognizing: Sendable {
    func recognize(image: ComposeScreenImage, maximumLines: Int, timeoutMilliseconds: Int) async throws -> ComposeOCRResult
}

/// This adapter is intentionally unavailable until a local Vision-backed
/// implementation is registered by a later platform integration. The service
/// remains testable through `ComposeScreenOCRRecognizing` fakes and fails
/// closed instead of silently substituting another OCR provider.
struct UnsupportedComposeScreenOCRAdapter: ComposeScreenOCRRecognizing {
    func recognize(image _: ComposeScreenImage, maximumLines _: Int, timeoutMilliseconds _: Int) async throws -> ComposeOCRResult {
        throw ComposeScreenPlatformFailure.unsupported
    }
}
