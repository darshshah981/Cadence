import Foundation

enum ScribeDiagnosticKind: String, Codable, Equatable, Sendable {
    case readinessChanged
    case setupOpened
    case setupClosed
    case validationStarted
    case validationCompleted
    case captureStarted
    case captureCompleted
    case transcriptionStarted
    case transcriptionCompleted
    case generationStarted
    case generationCompleted
    case manualRetryRequested
    case reviewFallbackChosen
    case insertionVerificationCompleted
    case providerRemoved
    case migrationCompleted
}

enum ScribeDiagnosticPhase: String, Codable, Equatable, Sendable {
    case readiness
    case setup
    case validation
    case capture
    case transcription
    case generation
    case review
    case insertion
    case migration
}

enum ScribeDiagnosticProvider: String, Codable, Equatable, Sendable {
    case none
    case deepSeek
    case openAIDirect
    case openRouter
    case advanced
    case legacyLocal
}

enum ScribeDiagnosticOutcome: String, Codable, Equatable, Sendable {
    case success
    case cancelled
    case permissionDenied
    case setupRequired
    case configurationInvalid
    case credentialRejected
    case balanceRequired
    case rateLimited
    case transportUnavailable
    case timedOut
    case providerUnavailable
    case providerRejected
    case invalidResponse
    case transcriptionEmpty
    case transcriptionFailed
    case targetChanged
    case insertionFailed
    case migrated
    case retained
    case failed
    case otherSafeCategory
}

enum ScribeDiagnosticLatency: String, Codable, Equatable, Sendable {
    case underOneSecond
    case oneToFourSeconds
    case fourToEightSeconds
    case eightToFifteenSeconds
    case fifteenToThirtySeconds
    case overThirtySeconds
    case notApplicable
}

enum ScribeDiagnosticAttempt: String, Codable, Equatable, Sendable {
    case first
    case second
    case thirdOrLater
    case notApplicable
}

enum ScribeDiagnosticRetry: String, Codable, Equatable, Sendable {
    case none
    case manualNow
    case manualAfterWait
    case reconnect
    case updateCadence
    case changeConfiguration
}

struct ScribeDiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let kind: ScribeDiagnosticKind
    let phase: ScribeDiagnosticPhase
    let provider: ScribeDiagnosticProvider
    let outcome: ScribeDiagnosticOutcome
    let latency: ScribeDiagnosticLatency
    let attempt: ScribeDiagnosticAttempt
    let retry: ScribeDiagnosticRetry
    let appAdaptationEnabled: Bool
    let selectedTextIntent: Bool
    let fallbackUsed: Bool
    let lateResultSuppressed: Bool

    init(
        timestamp: Date = Date(),
        kind: ScribeDiagnosticKind,
        phase: ScribeDiagnosticPhase,
        provider: ScribeDiagnosticProvider,
        outcome: ScribeDiagnosticOutcome,
        latency: ScribeDiagnosticLatency = .notApplicable,
        attempt: ScribeDiagnosticAttempt = .notApplicable,
        retry: ScribeDiagnosticRetry = .none,
        appAdaptationEnabled: Bool = false,
        selectedTextIntent: Bool = false,
        fallbackUsed: Bool = false,
        lateResultSuppressed: Bool = false
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.phase = phase
        self.provider = provider
        self.outcome = outcome
        self.latency = latency
        self.attempt = attempt
        self.retry = retry
        self.appAdaptationEnabled = appAdaptationEnabled
        self.selectedTextIntent = selectedTextIntent
        self.fallbackUsed = fallbackUsed
        self.lateResultSuppressed = lateResultSuppressed
    }

    func timestamped(_ date: Date) -> ScribeDiagnosticEvent {
        ScribeDiagnosticEvent(
            timestamp: date,
            kind: kind,
            phase: phase,
            provider: provider,
            outcome: outcome,
            latency: latency,
            attempt: attempt,
            retry: retry,
            appAdaptationEnabled: appAdaptationEnabled,
            selectedTextIntent: selectedTextIntent,
            fallbackUsed: fallbackUsed,
            lateResultSuppressed: lateResultSuppressed
        )
    }
}

struct ScribeDiagnosticRingEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let events: [ScribeDiagnosticEvent]

    init(
        schemaVersion: Int = ScribeDiagnosticRingEnvelope.currentSchemaVersion,
        events: [ScribeDiagnosticEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.events = events
    }
}

enum ScribeDiagnosticReadiness: String, Codable, Equatable, Sendable {
    case disabled
    case setupRequired
    case validating
    case ready
    case temporarilyUnavailable
    case configurationInvalid
    case needsAttention
    case deprecated
    case removed
}

struct ScribeDiagnosticPermissionSnapshot: Codable, Equatable, Sendable {
    let microphone: Bool
    let accessibility: Bool
    let inputMonitoring: Bool
}

struct ScribeDiagnosticsExport: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let build: String
    let macOSMajorVersion: Int
    let readiness: ScribeDiagnosticReadiness
    let permissions: ScribeDiagnosticPermissionSnapshot
    let provider: ScribeDiagnosticProvider
    let appAdaptationEnabled: Bool
    let events: [ScribeDiagnosticEvent]
}
