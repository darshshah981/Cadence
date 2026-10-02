import Foundation
import OSLog
#if canImport(CoreGraphics)
import CoreGraphics
#endif

private let composeScreenContextLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ComposeScreenContext"
)

/// Opaque capture bytes. They are never returned by a snapshot, serialized,
/// logged, or cached by the service. A cancelled platform operation can retain
/// its input until that operation actually unwinds.
final class ComposeScreenImage: @unchecked Sendable {
    let width: Int
    let height: Int
#if canImport(CoreGraphics)
    let cgImage: CGImage?
    init(cgImage: CGImage) { self.cgImage = cgImage; width = cgImage.width; height = cgImage.height }
#endif
    init(width: Int, height: Int) {
        self.width = width; self.height = height
#if canImport(CoreGraphics)
        cgImage = nil
#endif
    }
}

/// Platform capture is deliberately behind this narrow seam. Implementations
/// must capture exactly the supplied window, never choose a display or infer a
/// window from a title. They must not request Screen Recording permission.
protocol ComposeScreenCapturing: Sendable {
    func capture(
        window: ComposeScreenWindowIdentity,
        timeoutMilliseconds: Int
    ) async throws -> ComposeScreenImage
}

/// Rechecks the same action/window/process relationship before and after each
/// asynchronous boundary. It is a separate authority from OCR and capture.
protocol ComposeScreenTargetVerifying: Sendable {
    func verify(_ target: ComposeScreenContextTarget) async -> Bool
}

/// A deny-by-default adapter for builds without a certified exact-window
/// ScreenCaptureKit identity adapter. It performs no permission query or
/// capture, which is safer than guessing from the focused application.
struct UnsupportedComposeScreenCaptureAdapter: ComposeScreenCapturing {
    func capture(window _: ComposeScreenWindowIdentity, timeoutMilliseconds _: Int) async throws -> ComposeScreenImage {
        throw ComposeScreenPlatformFailure.unsupported
    }
}

/// One invocation, one pinned external window, and local-only OCR. The image
/// remains a local variable and is never retained by the returned snapshot.
@MainActor
final class ComposeScreenContextService {
    private let captureAdapter: any ComposeScreenCapturing
    private let ocr: any ComposeScreenOCRRecognizing
    private let verifier: any ComposeScreenTargetVerifying
    private let policy: @MainActor () -> ScribeContextPolicySnapshot
    private let permissions: @MainActor () -> ScribeContextPlatformPermissions
    private let currentTarget: @MainActor () -> ComposeScreenContextTarget?
    private let now: @MainActor () -> Date
    /// Synchronous seam for exercising the final publication boundary. It
    /// carries no content and does not replace authorization or the deadline.
    private let beforePublication: @MainActor () -> Void
    private let uptimeNanoseconds: @MainActor () -> UInt64

    init(
        captureAdapter: any ComposeScreenCapturing = UnsupportedComposeScreenCaptureAdapter(),
        ocr: any ComposeScreenOCRRecognizing,
        verifier: any ComposeScreenTargetVerifying,
        policy: @escaping @MainActor () -> ScribeContextPolicySnapshot = { .init() },
        permissions: @escaping @MainActor () -> ScribeContextPlatformPermissions = { .init() },
        currentTarget: @escaping @MainActor () -> ComposeScreenContextTarget? = { nil },
        now: @escaping @MainActor () -> Date = Date.init,
        beforePublication: @escaping @MainActor () -> Void = {},
        uptimeNanoseconds: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.captureAdapter = captureAdapter
        self.ocr = ocr
        self.verifier = verifier
        self.policy = policy
        self.permissions = permissions
        self.currentTarget = currentTarget
        self.now = now
        self.beforePublication = beforePublication
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    func capture(
        target: ComposeScreenContextTarget,
        budget: ComposeScreenCaptureBudget = .init()
    ) async -> ComposeScreenCaptureOutcome {
        guard target.isValid else { return .unavailable(.invalidTarget) }
        guard budget.isValid else { return .unavailable(.invalidBudget) }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }

        let startedAt = uptimeNanoseconds()
        let duration = UInt64(budget.timeoutMilliseconds) * 1_000_000
        let deadline = startedAt.addingReportingOverflow(duration)
        let withinDeadline = { @MainActor [uptimeNanoseconds] in
            let current = uptimeNanoseconds()
            return !deadline.overflow && current >= startedAt && current < deadline.partialValue
        }
        let race = ComposeScreenCaptureRace(withinDeadline: withinDeadline)
        do {
            let snapshot = try await withTaskCancellationHandler(operation: {
                try await race.run(timeoutMilliseconds: budget.timeoutMilliseconds) {
                    try await self.captureWithinDeadline(target: target, budget: budget)
                }
            }, onCancel: {
                Task { @MainActor in race.cancel() }
            })
            try Task.checkCancellation()
            beforePublication()
            // Resuming the deadline race is itself an async boundary. A
            // queued permission/action change can invalidate the inner result.
            try validateLiveState(snapshot.target, authorization: snapshot.authorization,
                                  request: .init(action: snapshot.target.action, operation: .capture(.screenshot)))
            guard withinDeadline() else { throw ComposeScreenCaptureFailure.timedOut }
            return .captured(snapshot)
        } catch let rejection as ScribeContextPolicyRejection {
            return .unavailable(.policy(rejection))
        } catch let failure as ComposeScreenCaptureFailure {
            return .unavailable(failure)
        } catch let failure as ComposeScreenPlatformFailure {
            return .unavailable(map(failure))
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            // Do not log screen text, image bytes, target metadata, or raw
            // platform errors. Callers receive only this typed outcome.
            composeScreenContextLogger.debug("Screen context operation unavailable")
            return .unavailable(.captureFailed)
        }
    }

    private func captureWithinDeadline(
        target: ComposeScreenContextTarget,
        budget: ComposeScreenCaptureBudget
    ) async throws -> ComposeScreenContextSnapshot {
        let request = ScribeContextPolicyRequest(action: target.action, operation: .capture(.screenshot))
        try validateLiveTarget(target)
        let authorization = try ScribeContextPolicy.authorize(
            request,
            using: policy(),
            permissions: permissions(),
            at: now()
        )

        guard await verifier.verify(target) else { throw ComposeScreenCaptureFailure.targetChanged }
        try validateLiveState(target, authorization: authorization, request: request)

        let image = try await captureAdapter.capture(window: target.window, timeoutMilliseconds: budget.timeoutMilliseconds)
        try throwIfCancelled()
        try validateLiveState(target, authorization: authorization, request: request)
        guard validImage(image, maximumPixels: budget.maximumPixels) else {
            throw ComposeScreenCaptureFailure.imageTooLarge
        }

        guard await verifier.verify(target) else { throw ComposeScreenCaptureFailure.targetChanged }
        try validateLiveState(target, authorization: authorization, request: request)

        let recognized = try await ocr.recognize(
            image: image,
            maximumLines: budget.maximumRecognizedLines,
            timeoutMilliseconds: budget.timeoutMilliseconds
        )
        try throwIfCancelled()
        try validateLiveState(target, authorization: authorization, request: request)
        guard await verifier.verify(target) else { throw ComposeScreenCaptureFailure.targetChanged }
        try validateLiveState(target, authorization: authorization, request: request)

        return try makeSnapshot(recognized, target: target, budget: budget, authorization: authorization)
    }

    private func makeSnapshot(
        _ recognized: ComposeOCRResult,
        target: ComposeScreenContextTarget,
        budget: ComposeScreenCaptureBudget,
        authorization: ScribeContextAccessAuthorization
    ) throws -> ComposeScreenContextSnapshot {
        var limitations: Set<ComposeScreenContextLimitation> = recognized.isClipped ? [.clipped] : []
        if recognized.hasAmbiguousColumns { limitations.insert(.ambiguousColumns) }
        if recognized.lines.count > budget.maximumRecognizedLines { limitations.insert(.lineLimit) }

        var retainedLines: [ComposeOCRLine] = []
        var retainedBytes = 0
        for line in recognized.lines.prefix(budget.maximumRecognizedLines) {
            guard valid(line) else { throw ComposeScreenCaptureFailure.recognitionFailed }
            let separatorBytes = retainedLines.isEmpty ? 0 : 1
            let candidateBytes = line.text.utf8.count + separatorBytes
            guard retainedBytes + candidateBytes <= budget.maximumUTF8Bytes else {
                limitations.insert(.byteLimit)
                break
            }
            retainedLines.append(line)
            retainedBytes += candidateBytes
        }
        guard !retainedLines.isEmpty else {
            if recognized.lines.isEmpty { throw ComposeScreenCaptureFailure.noRecognizedText }
            throw ComposeScreenCaptureFailure.contextTooLarge
        }
        if retainedLines.contains(where: { $0.confidence < budget.minimumConfidence }) {
            limitations.insert(.lowConfidence)
        }
        // Retaining whole OCR lines preserves valid Unicode and means every
        // byte of source text returned in `lines` is also present in screenText.
        let screenText = retainedLines.map(\.text).joined(separator: "\n")
        return .init(id: UUID(), target: target, screenText: screenText, lines: retainedLines,
                     capturedAt: now(), authorization: authorization, limitations: limitations)
    }

    private func validateLiveState(
        _ target: ComposeScreenContextTarget,
        authorization: ScribeContextAccessAuthorization,
        request: ScribeContextPolicyRequest
    ) throws {
        try validateLiveTarget(target)
        try ScribeContextPolicy.revalidate(authorization, for: request, using: policy(), permissions: permissions(), at: now())
    }

    private func validateLiveTarget(_ target: ComposeScreenContextTarget) throws {
        try Task.checkCancellation()
        guard currentTarget() == target else { throw ComposeScreenCaptureFailure.targetChanged }
    }

    private func throwIfCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    private func validImage(_ image: ComposeScreenImage, maximumPixels: Int) -> Bool {
        image.width > 0 && image.height > 0
            && !image.width.multipliedReportingOverflow(by: image.height).overflow
            && image.width * image.height <= maximumPixels
    }

    private func valid(_ line: ComposeOCRLine) -> Bool {
        guard !line.text.isEmpty, line.confidence.isFinite, (0...1).contains(line.confidence) else { return false }
        let box = line.boundingBox
        return box.origin.x.isFinite && box.origin.y.isFinite
            && box.width.isFinite && box.height.isFinite
            && box.origin.x >= 0 && box.origin.y >= 0
            && box.width > 0 && box.height > 0
            && box.maxX <= 1 && box.maxY <= 1
    }

    private func map(_ failure: ComposeScreenPlatformFailure) -> ComposeScreenCaptureFailure {
        switch failure {
        case .unsupported, .targetUnavailable: return .unsupported
        case .permissionDenied: return .permissionDenied
        case .timedOut: return .timedOut
        case .captureFailed: return .captureFailed
        case .recognitionFailed: return .recognitionFailed
        }
    }
}

/// Owns the wall-clock deadline for the entire operation. Cancelling its
/// continuation returns promptly even if a platform adapter ignores
/// cancellation; a late completion cannot resume the caller a second time.
@MainActor
private final class ComposeScreenCaptureRace {
    private let withinDeadline: @MainActor () -> Bool
    private var continuation: CheckedContinuation<ComposeScreenContextSnapshot, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    init(withinDeadline: @escaping @MainActor () -> Bool) { self.withinDeadline = withinDeadline }

    func run(
        timeoutMilliseconds: Int,
        operation: @escaping @MainActor () async throws -> ComposeScreenContextSnapshot
    ) async throws -> ComposeScreenContextSnapshot {
        // Cancellation can win before the continuation is installed.
        guard !finished else { throw ComposeScreenCaptureFailure.cancelled }
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            work = Task {
                guard self.withinDeadline() else { self.finish(.failure(ComposeScreenCaptureFailure.timedOut)); return }
                do { self.finish(.success(try await operation())) }
                catch { self.finish(.failure(error)) }
            }
            timer = Task {
                try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
                guard !Task.isCancelled else { return }
                self.finish(.failure(ComposeScreenCaptureFailure.timedOut))
            }
        }
    }

    func cancel() {
        finish(.failure(ComposeScreenCaptureFailure.cancelled))
    }

    private func finish(_ result: Result<ComposeScreenContextSnapshot, Error>) {
        guard !finished else { return }
        let finalResult: Result<ComposeScreenContextSnapshot, Error> = {
            if case .success = result, !withinDeadline() { return .failure(ComposeScreenCaptureFailure.timedOut) }
            return result
        }()
        finished = true
        timer?.cancel()
        work?.cancel()
        continuation?.resume(with: finalResult)
        continuation = nil
    }
}
