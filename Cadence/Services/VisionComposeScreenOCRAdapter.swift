import Foundation
import CoreGraphics
import Vision
import OSLog

private let visionComposeScreenOCRLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "ComposeVisionOCR"
)

/// Local recognition of an already supplied image. This adapter does not
/// capture a screen, request permissions, persist images, or select a target.
/// The initial language contract is English; lexical correction is disabled
/// so recognized names and technical text are not rewritten by that feature.
struct VisionComposeScreenOCRAdapter: ComposeScreenOCRRecognizing {
    private let workQueue: DispatchQueue
    private let onWorkScheduled: (@Sendable () -> Void)?

    init() {
        workQueue = DispatchQueue(label: "Cadence.ComposeVisionOCR", qos: .userInitiated)
        onWorkScheduled = nil
    }

    /// A background queue seam for deterministic cancellation/deadline tests.
    /// Live callers use the dedicated queue created by the default initializer.
    init(workQueue: DispatchQueue, onWorkScheduled: (@Sendable () -> Void)? = nil) {
        self.workQueue = workQueue
        self.onWorkScheduled = onWorkScheduled
    }

    func recognize(
        image: ComposeScreenImage,
        maximumLines: Int,
        timeoutMilliseconds: Int
    ) async throws -> ComposeOCRResult {
        try Task.checkCancellation()
        guard let cgImage = image.cgImage,
              (1...8_192).contains(image.width),
              (1...8_192).contains(image.height),
              image.width <= 16_000_000 / image.height,
              (1...200).contains(maximumLines),
              (1...10_000).contains(timeoutMilliseconds) else {
            throw ComposeScreenPlatformFailure.recognitionFailed
        }

        let operation = VisionComposeRecognitionOperation(image: cgImage, timeoutMilliseconds: timeoutMilliseconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                guard operation.isPending else { return }
                let timeout = Task {
                    do {
                        try await Task.sleep(nanoseconds: operation.remainingNanoseconds)
                        operation.finish(.failure(ComposeScreenPlatformFailure.timedOut), cancelVision: true)
                    } catch {
                        // A result or explicit cancellation already won.
                    }
                }
                operation.install(timeout: timeout)

                workQueue.async {
                    autoreleasepool {
                        guard operation.isPending else { return }
                        // The injected queue cannot accidentally run Vision on
                        // the main thread, even when a caller misconfigures it.
                        guard !Thread.isMainThread else {
                            operation.finish(.failure(ComposeScreenPlatformFailure.recognitionFailed))
                            return
                        }
                        let request = VNRecognizeTextRequest()
                        request.revision = VNRecognizeTextRequestRevision3
                        request.recognitionLevel = .accurate
                        request.recognitionLanguages = ["en-US"]
                        request.usesLanguageCorrection = false
                        request.automaticallyDetectsLanguage = false
                        guard let activeImage = operation.begin(request: request), operation.isPending else { return }

                        do {
                            let handler = VNImageRequestHandler(cgImage: activeImage, orientation: .up, options: [:])
                            try handler.perform([request])
                            guard operation.isPending else { return }
                            let result = Self.boundedResult(request.results ?? [], maximumLines: maximumLines)
                            operation.finish(.success(result))
                        } catch {
                            // Cancellation/timeout owns its earlier result;
                            // remaining platform failures have a coarse code.
                            operation.finish(.failure(ComposeScreenPlatformFailure.recognitionFailed))
                        }
                    }
                }
                onWorkScheduled?()
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()), cancelVision: true)
        }
    }

    private static func boundedResult(
        _ observations: [VNRecognizedTextObservation],
        maximumLines: Int
    ) -> ComposeOCRResult {
        // Vision uses normalized, lower-left image coordinates. This is a
        // deterministic single-column order, not certified document layout.
        let ordered = observations.enumerated().filter { entry in
            let box = entry.element.boundingBox
            return box.origin.x.isFinite && box.origin.y.isFinite
                && box.width.isFinite && box.height.isFinite
                && box.maxX.isFinite && box.maxY.isFinite
                && box.width > 0 && box.height > 0
        }.sorted { lhs, rhs in
            let left = lhs.element.boundingBox
            let right = rhs.element.boundingBox
            if left.maxY != right.maxY { return left.maxY > right.maxY }
            if left.minX != right.minX { return left.minX < right.minX }
            return lhs.offset < rhs.offset
        }
        var lines: [ComposeOCRLine] = []
        var utf8Bytes = 0
        var isClipped = ordered.count != observations.count

        for entry in ordered {
            guard lines.count < maximumLines else {
                isClipped = true
                break
            }
            let observation = entry.element
            guard let candidate = observation.topCandidates(1).first else {
                isClipped = true
                continue
            }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                isClipped = true
                continue
            }
            let box = observation.boundingBox
            guard candidate.confidence.isFinite,
                  (0...1).contains(candidate.confidence) else {
                isClipped = true
                continue
            }
            let normalizedBox = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !normalizedBox.isNull, !normalizedBox.isEmpty else {
                isClipped = true
                continue
            }
            isClipped = isClipped || normalizedBox != box
            let lineBytes = text.utf8.count + (lines.isEmpty ? 0 : 1)
            guard lineBytes <= 32 * 1_024 - utf8Bytes else {
                isClipped = true
                break
            }
            lines.append(ComposeOCRLine(text: text, confidence: candidate.confidence, boundingBox: normalizedBox))
            utf8Bytes += lineBytes
        }
        return ComposeOCRResult(
            lines: lines,
            isClipped: isClipped,
            hasAmbiguousColumns: hasSeparateColumns(in: lines.map(\.boundingBox))
        )
    }

    /// A separated, vertically overlapping pair of text groups cannot be
    /// safely flattened into the single-column reading order above. This is
    /// a limitation signal, not an attempt to infer which column matters.
    static func hasSeparateColumns(in boxes: [CGRect]) -> Bool {
        guard boxes.count >= 4 else { return false }
        let sorted = boxes.sorted { $0.minX < $1.minX }
        for split in 2...(sorted.count - 2) {
            let left = sorted[..<split]
            let right = sorted[split...]
            let leftBounds = left.reduce(CGRect.null) { $0.union($1) }
            let rightBounds = right.reduce(CGRect.null) { $0.union($1) }
            guard leftBounds.maxX + 0.08 <= rightBounds.minX,
                  leftBounds.height >= 0.12, rightBounds.height >= 0.12 else { continue }
            let overlap = min(leftBounds.maxY, rightBounds.maxY)
                - max(leftBounds.minY, rightBounds.minY)
            if overlap >= 0.35 * min(leftBounds.height, rightBounds.height) {
                return true
            }
        }
        return false
    }
}

/// The lock owns the continuation, terminal result, deadline, and active
/// request. Vision's synchronous perform remains confined to the work queue;
/// only its documented cancellation entry point is called from another thread.
private final class VisionComposeRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ComposeOCRResult, Error>?
    private var result: Result<ComposeOCRResult, Error>?
    private var request: VNRecognizeTextRequest?
    private var timeout: Task<Void, Never>?
    private var queuedImage: CGImage?
    private let deadlineNanoseconds: UInt64

    init(image: CGImage, timeoutMilliseconds: Int) {
        queuedImage = image
        deadlineNanoseconds = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    }

    var remainingNanoseconds: UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now < deadlineNanoseconds ? deadlineNanoseconds - now : 0
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    func install(_ continuation: CheckedContinuation<ComposeOCRResult, Error>) {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func install(timeout: Task<Void, Never>) {
        lock.lock()
        let completed = result != nil
        if !completed { self.timeout = timeout }
        lock.unlock()
        if completed { timeout.cancel() }
    }

    func begin(request: VNRecognizeTextRequest) -> CGImage? {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return nil
        }
        guard remainingNanoseconds > 0 else {
            lock.unlock()
            finish(.failure(ComposeScreenPlatformFailure.timedOut), cancelVision: true)
            return nil
        }
        self.request = request
        let image = queuedImage
        queuedImage = nil
        lock.unlock()
        return image
    }

    func finish(_ result: Result<ComposeOCRResult, Error>, cancelVision: Bool = false) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        var finalResult = result
        var shouldCancelVision = cancelVision
        // A delayed deadline task cannot let a late platform completion cross
        // the monotonic deadline and appear timely to the caller.
        if !cancelVision, remainingNanoseconds == 0 {
            finalResult = .failure(ComposeScreenPlatformFailure.timedOut)
            shouldCancelVision = true
        }
        self.result = finalResult
        let continuation = self.continuation
        let timeout = self.timeout
        let request = self.request
        self.continuation = nil
        self.timeout = nil
        self.request = nil
        // Pending queue blocks retain only this state. A cancelled request
        // releases its image immediately unless Vision already began using it.
        queuedImage = nil
        lock.unlock()

        timeout?.cancel()
        // Return promptly even if the platform needs time to unwind. The
        // queued operation retains the image until that unwind finishes.
        continuation?.resume(with: finalResult)
        if shouldCancelVision { request?.cancel() }
    }
}
