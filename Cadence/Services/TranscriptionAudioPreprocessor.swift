import Foundation

enum TranscriptionAudioPreprocessor {
    private static let silenceWindowSize = 160
    private static let silenceThreshold: Float = 0.008
    private static let trimPaddingSamples = 2_400

    static func preprocess(_ samples: [Float], configuration: TranscriptionConfiguration) -> [Float] {
        var processed = samples

        if configuration.trimSilence {
            processed = trimSilence(in: processed)
        }

        if configuration.normalizeAudio {
            processed = normalizeAudio(processed)
        }

        return processed
    }

    private static func trimSilence(in samples: [Float]) -> [Float] {
        guard samples.count > silenceWindowSize else { return samples }

        let amplitudes = samples.map { abs($0) }
        var startIndex = 0
        var endIndex = samples.count

        var leadingWindowSum: Float = amplitudes.prefix(silenceWindowSize).reduce(0, +)
        var index = 0
        while index + silenceWindowSize <= amplitudes.count {
            let average = leadingWindowSum / Float(silenceWindowSize)
            if average >= silenceThreshold {
                startIndex = max(0, index - trimPaddingSamples)
                break
            }

            let outgoing = amplitudes[index]
            let incomingIndex = index + silenceWindowSize
            if incomingIndex < amplitudes.count {
                leadingWindowSum += amplitudes[incomingIndex] - outgoing
            }
            index += 1
            startIndex = samples.count
        }

        guard startIndex < samples.count else {
            return samples
        }

        var trailingWindowSum: Float = amplitudes.suffix(silenceWindowSize).reduce(0, +)
        index = amplitudes.count - silenceWindowSize
        while index >= 0 {
            let average = trailingWindowSum / Float(silenceWindowSize)
            if average >= silenceThreshold {
                endIndex = min(samples.count, index + silenceWindowSize + trimPaddingSamples)
                break
            }

            if index > 0 {
                trailingWindowSum += amplitudes[index - 1] - amplitudes[index + silenceWindowSize - 1]
            }
            index -= 1
            endIndex = 0
        }

        guard endIndex > startIndex else {
            return samples
        }

        return Array(samples[startIndex..<endIndex])
    }

    private static func normalizeAudio(_ samples: [Float]) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0.0001 else {
            return samples
        }

        let targetPeak: Float = 0.85
        let gain = min(targetPeak / peak, 8)
        guard gain > 1.05 else { return samples }

        return samples.map { sample in
            max(-1, min(1, sample * gain))
        }
    }
}
