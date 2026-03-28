import AVFoundation
import Foundation

protocol AudioCaptureServing: AnyObject {
    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws
    func stopCapture() -> AudioCaptureSessionMetrics
}

final class AudioCaptureService: AudioCaptureServing {
    private static let speechLevelThreshold = 0.03
    private static let prerollChunkLimit = 6

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var startDate: Date?
    private var totalFrames = 0
    private var speechFrames = 0
    private var currentSampleRate = 16_000.0
    private var speechDetected = false
    private var prerollChunks = [AudioChunk]()

    func startCapture(chunkHandler: @escaping @Sendable (AudioChunk, Double) -> Void) throws {
        let inputNode = engine.inputNode

        stopEngineIfNeeded()
        totalFrames = 0
        speechFrames = 0
        speechDetected = false
        prerollChunks.removeAll(keepingCapacity: true)
        startDate = Date()

        let inputFormat = inputNode.outputFormat(forBus: 0)
        currentSampleRate = targetFormat.sampleRate
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converter = self.converter,
                  let chunk = Self.makeChunk(from: buffer, converter: converter, targetFormat: self.targetFormat) else {
                return
            }
            let level = Self.calculateLevel(for: chunk.samples)
            self.totalFrames += chunk.frameCount

            if level >= Self.speechLevelThreshold {
                if !self.speechDetected {
                    self.speechDetected = true
                    for prerollChunk in self.prerollChunks {
                        chunkHandler(prerollChunk, level)
                        self.speechFrames += prerollChunk.frameCount
                    }
                    self.prerollChunks.removeAll(keepingCapacity: true)
                }

                self.speechFrames += chunk.frameCount
                chunkHandler(chunk, level)
            } else if self.speechDetected {
                chunkHandler(chunk, level)
            } else {
                self.prerollChunks.append(chunk)
                if self.prerollChunks.count > Self.prerollChunkLimit {
                    self.prerollChunks.removeFirst(self.prerollChunks.count - Self.prerollChunkLimit)
                }
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stopCapture() -> AudioCaptureSessionMetrics {
        let duration = Date().timeIntervalSince(startDate ?? Date())
        stopEngineIfNeeded()

        return AudioCaptureSessionMetrics(
            duration: duration,
            frameCount: totalFrames,
            sampleRate: currentSampleRate,
            speechDetected: speechDetected,
            speechFrameCount: speechFrames
        )
    }

    private func stopEngineIfNeeded() {
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        prerollChunks.removeAll(keepingCapacity: true)
        if engine.isRunning {
            engine.stop()
        }
    }

    private static func calculateLevel(for samples: [Float]) -> Double {
        guard !samples.isEmpty else {
            return 0
        }

        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }

        return min(1, Double(sqrt(sum / Float(samples.count)) * 8))
    }

    private static func makeChunk(
        from buffer: AVAudioPCMBuffer,
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
}
