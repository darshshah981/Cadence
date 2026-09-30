import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Cadence

/// Synthetic image coverage only. These tests do not capture a screen, request
/// permissions, write an image, or evaluate OCR on personal app content.
@Suite(.serialized)
@MainActor
struct VisionComposeScreenOCRTests {
    @Test
    func separatedOverlappingTextColumnsReportAmbiguousReadingOrder() {
        let columns = [
            CGRect(x: 0.08, y: 0.70, width: 0.30, height: 0.07),
            CGRect(x: 0.08, y: 0.48, width: 0.30, height: 0.07),
            CGRect(x: 0.58, y: 0.70, width: 0.30, height: 0.07),
            CGRect(x: 0.58, y: 0.48, width: 0.30, height: 0.07)
        ]
        #expect(VisionComposeScreenOCRAdapter.hasSeparateColumns(in: columns))
        let oneColumn = columns.map { box in
            CGRect(x: 0.08, y: box.minY, width: 0.70, height: box.height)
        }
        #expect(!VisionComposeScreenOCRAdapter.hasSeparateColumns(in: oneColumn))
        #expect(!VisionComposeScreenOCRAdapter.hasSeparateColumns(in: Array(columns.prefix(3))))
    }

    @Test
    func syntheticTwoColumnImageReportsLayoutLimitation() async throws {
        let result = try await VisionComposeScreenOCRAdapter().recognize(
            image: columnImage(), maximumLines: 20, timeoutMilliseconds: 10_000
        )
        #expect(result.lines.count >= 4)
        #expect(result.hasAmbiguousColumns)
    }

    @Test
    func recognizesSyntheticWordsWithNormalizedLowerLeftBoxesInReadingOrder() async throws {
        let image = try textImage()
        let result = try await VisionComposeScreenOCRAdapter().recognize(
            image: image, maximumLines: 10, timeoutMilliseconds: 10_000
        )
        #expect(!result.isClipped)
        let alpha = try #require(result.lines.firstIndex { $0.text.lowercased().contains("alpha") })
        let bravo = try #require(result.lines.firstIndex { $0.text.lowercased().contains("bravo") })
        let charlie = try #require(result.lines.firstIndex { $0.text.lowercased().contains("charlie") })
        #expect(alpha < bravo && bravo < charlie)
        #expect(result.lines[alpha].boundingBox.midY > result.lines[bravo].boundingBox.midY)
        #expect(result.lines[bravo].boundingBox.midY > result.lines[charlie].boundingBox.midY)
        for line in result.lines {
            #expect(!line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(line.confidence.isFinite && (0...1).contains(line.confidence))
            let box = line.boundingBox
            #expect(box.origin.x.isFinite && box.origin.y.isFinite)
            #expect(box.width.isFinite && box.height.isFinite)
            #expect(box.width > 0 && box.height > 0)
            #expect(box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1)
        }
    }

    @Test
    func lineLimitReturnsWholeLeadingLinesAndReportsClipping() async throws {
        let result = try await VisionComposeScreenOCRAdapter().recognize(
            image: textImage(), maximumLines: 2, timeoutMilliseconds: 10_000
        )
        #expect(result.lines.count == 2)
        #expect(result.isClipped)
        #expect(result.lines.first?.text.lowercased().contains("alpha") == true)
        #expect(result.lines.last?.text.lowercased().contains("bravo") == true)
        #expect(!result.lines.contains { $0.text.lowercased().contains("charlie") })
        #expect(result.lines.map(\.text).joined(separator: "\n").utf8.count <= 32 * 1_024)
    }

    @Test
    func blankImageReturnsNoLinesWithoutClaimingClipping() async throws {
        let result = try await VisionComposeScreenOCRAdapter().recognize(
            image: blankImage(width: 640, height: 240), maximumLines: 200, timeoutMilliseconds: 10_000
        )
        #expect(result.lines.isEmpty)
        #expect(!result.isClipped)
    }

    @Test
    func missingPixelPayloadAndImagesOverEitherHardCapAreRejected() async throws {
        let adapter = VisionComposeScreenOCRAdapter()
        let missingImages = [
            ComposeScreenImage(width: 100, height: 40),
            ComposeScreenImage(width: 0, height: 40),
            ComposeScreenImage(width: -1, height: 40),
            ComposeScreenImage(width: Int.max, height: Int.max)
        ]
        for image in missingImages {
            await #expect(throws: ComposeScreenPlatformFailure.recognitionFailed) {
                try await adapter.recognize(image: image, maximumLines: 1, timeoutMilliseconds: 100)
            }
        }
        // Real, small grayscale payload checks the dimension cap independently
        // of the missing-payload path. The second payload exceeds only pixels.
        for (width, height) in [(8_193, 2), (4_001, 4_000)] {
            let image = try blankImage(width: width, height: height)
            await #expect(throws: ComposeScreenPlatformFailure.recognitionFailed) {
                try await adapter.recognize(image: image, maximumLines: 1, timeoutMilliseconds: 100)
            }
        }
    }

    @Test
    func invalidLineAndDeadlineBoundsFailBeforeRecognition() async throws {
        let image = try blankImage(width: 100, height: 40)
        let adapter = VisionComposeScreenOCRAdapter()
        let invalidBudgets = [
            (lines: 0, timeout: 100), (lines: -1, timeout: 100),
            (lines: 201, timeout: 100), (lines: Int.max, timeout: 100),
            (lines: 1, timeout: 0), (lines: 1, timeout: -1),
            (lines: 1, timeout: 10_001), (lines: 1, timeout: Int.max)
        ]
        for budget in invalidBudgets {
            await #expect(throws: ComposeScreenPlatformFailure.recognitionFailed) {
                try await adapter.recognize(image: image, maximumLines: budget.lines, timeoutMilliseconds: budget.timeout)
            }
        }
    }

    @Test
    func deadlineFinishesWhileRecognitionQueueIsSuspended() async throws {
        let queue = DispatchQueue(label: "CadenceTests.VisionOCR.timeout")
        queue.suspend()
        // Always balance suspend, including a thrown fixture error or failed
        // assertion. A suspended queue must never be released at test exit.
        defer { queue.resume() }
        let adapter = VisionComposeScreenOCRAdapter(workQueue: queue)
        let image = try textImage()
        await #expect(throws: ComposeScreenPlatformFailure.timedOut) {
            try await adapter.recognize(image: image, maximumLines: 10, timeoutMilliseconds: 30)
        }
    }

    @Test
    func alreadyCancelledTaskDoesNotWaitForRecognitionQueue() async throws {
        let queue = DispatchQueue(label: "CadenceTests.VisionOCR.precancelled")
        queue.suspend()
        defer { queue.resume() }
        let image = try textImage()
        let adapter = VisionComposeScreenOCRAdapter(workQueue: queue)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.recognize(image: image, maximumLines: 10, timeoutMilliseconds: 10_000)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func cancellationFinishesAfterWorkIsQueuedWithoutResumingTheWorker() async throws {
        let queue = DispatchQueue(label: "CadenceTests.VisionOCR.queued-cancellation")
        queue.suspend()
        defer { queue.resume() }
        let scheduled = VisionOCRWorkScheduledSignal()
        let adapter = VisionComposeScreenOCRAdapter(workQueue: queue, onWorkScheduled: {
            Task { await scheduled.markScheduled() }
        })
        let image = try textImage()
        let task = Task {
            try await adapter.recognize(image: image, maximumLines: 10, timeoutMilliseconds: 10_000)
        }
        await scheduled.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func textImage() throws -> ComposeScreenImage {
        let width = 1_200
        let height = 600
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        for (index, text) in ["Alpha meadow", "Bravo river", "Charlie forest"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 80, y: CGFloat(450 - index * 160)), withAttributes: attributes)
        }
        return ComposeScreenImage(cgImage: try #require(bitmap.makeImage()))
    }

    private func columnImage() throws -> ComposeScreenImage {
        let width = 1_400, height = 700
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 48, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        for (text, x, y) in [
            ("Alpha meadow", 80, 500), ("Bravo river", 80, 280),
            ("Charlie forest", 800, 500), ("Delta garden", 800, 280)
        ] {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
        }
        return ComposeScreenImage(cgImage: try #require(bitmap.makeImage()))
    }

    private func blankImage(width: Int, height: Int) throws -> ComposeScreenImage {
        let bitmap = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return ComposeScreenImage(cgImage: try #require(bitmap.makeImage()))
    }
}

private actor VisionOCRWorkScheduledSignal {
    private var isScheduled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func markScheduled() {
        isScheduled = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if isScheduled { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
