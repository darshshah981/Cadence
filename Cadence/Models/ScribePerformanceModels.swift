import Foundation

/// Content-free milestones for local Compose responsiveness diagnostics.
/// They describe application work only; they never contain transcript, target,
/// provider configuration, or model output.
enum ScribePerformanceStage: String, CaseIterable, Codable, Sendable {
    case permissionsChecked
    case providerPreflightCompleted
    case transcriptionConfigured
    case targetPinned
    case listening
    case firstAudioFrame
    case transcriptionFinished
    case generationStarted
    case reviewReady
    case insertionAttempted
}

enum ScribePerformanceTerminalOutcome: String, Codable, Sendable {
    case completed
    case cancelled
    case failed
}

struct ScribePerformanceStageTiming: Equatable, Codable, Sendable {
    let stage: ScribePerformanceStage
    /// Offset from `begin`, measured by an injected monotonic clock.
    let elapsedNanoseconds: UInt64
}

struct ScribePerformanceSample: Equatable, Codable, Sendable {
    let actionID: UUID
    let stages: [ScribePerformanceStageTiming]
    let terminalOutcome: ScribePerformanceTerminalOutcome
    let totalElapsedNanoseconds: UInt64
}

struct ScribePerformanceTimingSummary: Equatable, Sendable {
    let sampleCount: Int
    let p50Nanoseconds: UInt64?
    let p95Nanoseconds: UInt64?
}
