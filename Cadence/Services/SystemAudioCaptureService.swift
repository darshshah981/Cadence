import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

private let systemAudioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Cadence",
    category: "SystemAudio"
)

enum SystemAudioCaptureError: LocalizedError {
    case screenRecordingPermissionRequired
    case noDisplayAvailable(
        screenCount: Int,
        activeDisplayCount: UInt32,
        shareableDisplayCount: Int,
        applicationCount: Int
    )
    case audioOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionRequired:
            return "Screen Recording permission is required to capture system audio."
        case let .noDisplayAvailable(screenCount, activeDisplayCount, shareableDisplayCount, applicationCount):
            return "Cadence could not find a display to attach system audio capture to. Diagnostics: NSScreen=\(screenCount), CoreGraphics active displays=\(activeDisplayCount), ScreenCaptureKit displays=\(shareableDisplayCount), apps=\(applicationCount)."
        case .audioOutputUnavailable:
            return "Cadence could not read system audio from the capture stream."
        }
    }
}

enum SystemAudioCaptureState: Equatable {
    case idle
    case starting
    case capturing
    case stopping
    case failed(String)

    var isCapturing: Bool {
        if case .capturing = self {
            return true
        }
        return false
    }

    var isCaptureBusy: Bool {
        self == .starting || self == .capturing || self == .stopping
    }
}

protocol SystemAudioCaptureServing: AnyObject {
    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) async throws
    func stopCapture() async -> AudioCaptureSessionMetrics
}

final class SystemAudioCaptureService: NSObject, SystemAudioCaptureServing {
    private static let sampleRate = 16_000.0

    private let outputQueue = DispatchQueue(label: "com.darshshah.Cadence.system-audio")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!

    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var chunkHandler: (@Sendable (AudioChunk, Double) -> Void)?
    private var startDate: Date?
    private var totalFrames = 0
    private var speechFrames = 0
    private var speechDetected = false
    private var peakLevel = 0.0

    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw SystemAudioCaptureError.screenRecordingPermissionRequired
        }

        await stopCapture()
        resetMetrics()
        self.chunkHandler = chunkHandler
        startDate = Date()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let screenCount = NSScreen.screens.count
        let activeDisplayCount = Self.activeDisplayCount()
        systemAudioLogger.info("System audio shareable content screens=\(screenCount, privacy: .public) activeDisplays=\(activeDisplayCount, privacy: .public) shareableDisplays=\(content.displays.count, privacy: .public) apps=\(content.applications.count, privacy: .public)")
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable(
                screenCount: screenCount,
                activeDisplayCount: activeDisplayCount,
                shareableDisplayCount: content.displays.count,
                applicationCount: content.applications.count
            )
        }

        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter { application in
            application.bundleIdentifier == currentBundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = Int(Self.sampleRate)
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.width = max(display.width, 2)
        configuration.height = max(display.height, 2)
        configuration.queueDepth = 8
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
        systemAudioLogger.info("System audio capture started display=\(display.displayID, privacy: .public) displays=\(content.displays.count, privacy: .public) apps=\(content.applications.count, privacy: .public) excludedApps=\(excludedApplications.count, privacy: .public) sampleRate=\(Int(Self.sampleRate), privacy: .public) channels=1 queueDepth=8 excludesCurrentProcess=true")
    }

    @discardableResult
    func stopCapture() async -> AudioCaptureSessionMetrics {
        let duration = Date().timeIntervalSince(startDate ?? Date())
        let activeStream = stream
        stream = nil
        converter = nil
        chunkHandler = nil
        startDate = nil

        if let activeStream {
            try? activeStream.removeStreamOutput(self, type: .audio)
            try? await activeStream.stopCapture()
            await drainOutputQueue()
        }

        let metrics = AudioCaptureSessionMetrics(
            duration: duration,
            frameCount: totalFrames,
            sampleRate: Self.sampleRate,
            speechDetected: speechDetected || totalFrames > 0,
            speechFrameCount: max(speechFrames, totalFrames),
            peakLevel: peakLevel
        )
        systemAudioLogger.info("System audio capture stopped duration=\(duration, privacy: .public) frames=\(self.totalFrames, privacy: .public) speechFrames=\(self.speechFrames, privacy: .public) peak=\(self.peakLevel, privacy: .public)")
        return metrics
    }

    private func drainOutputQueue() async {
        await withCheckedContinuation { continuation in
            outputQueue.async {
                continuation.resume()
            }
        }
    }

    private func resetMetrics() {
        totalFrames = 0
        speechFrames = 0
        speechDetected = false
        peakLevel = 0
    }

    private static func activeDisplayCount() -> UInt32 {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        return count
    }

    private func handle(sampleBuffer: CMSampleBuffer) {
        guard let chunk = Self.makeChunk(
            from: sampleBuffer,
            converter: &converter,
            targetFormat: targetFormat
        ) else {
            return
        }

        let level = Self.calculateLevel(for: chunk.samples)
        totalFrames += chunk.frameCount
        if level > 0.008 {
            speechDetected = true
            speechFrames += chunk.frameCount
        }
        peakLevel = max(peakLevel, level)
        chunkHandler?(chunk, level)
    }

    private static func makeChunk(
        from sampleBuffer: CMSampleBuffer,
        converter: inout AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) -> AudioChunk? {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }

        sourceBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            return nil
        }

        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }

        guard let converter else {
            return nil
        }

        return convert(sourceBuffer, converter: converter, targetFormat: targetFormat)
    }

    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> AudioChunk? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 16
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil, status != .error, let channelData = convertedBuffer.floatChannelData?[0] else {
            return nil
        }

        let frameLength = Int(convertedBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
        return AudioChunk(samples: samples, frameCount: frameLength, sampleRate: targetFormat.sampleRate)
    }

    private static func calculateLevel(for samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return min(1, Double(sqrt(sum / Float(samples.count)) * 8))
    }
}

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handle(sampleBuffer: sampleBuffer)
    }
}

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        chunkHandler = nil
    }
}
