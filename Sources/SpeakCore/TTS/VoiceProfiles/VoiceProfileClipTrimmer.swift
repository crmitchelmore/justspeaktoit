import Foundation

/// Output of `VoiceProfileClipTrimmer`, including the chosen time window and quality evaluation.
public struct VoiceProfileTrimResult: Equatable, Sendable {
    public let buffer: VoiceProfilePCMBuffer
    public let startTimeSeconds: Double
    public let endTimeSeconds: Double
    public let originalDurationSeconds: Double
    public let qualityReport: VoiceProfileQualityReport

    public init(
        buffer: VoiceProfilePCMBuffer,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        originalDurationSeconds: Double,
        qualityReport: VoiceProfileQualityReport
    ) {
        self.buffer = buffer
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.originalDurationSeconds = originalDurationSeconds
        self.qualityReport = qualityReport
    }

    public var trimmedDurationSeconds: Double {
        buffer.durationSeconds
    }
}

/// Selects the cleanest 10-20s speech segment from longer History or imported recordings using portable VAD.
public struct VoiceProfileClipTrimmer: Sendable {
    public let targetMinimumSeconds: Double
    public let targetMaximumSeconds: Double
    public let preferredSeconds: Double
    public let absoluteMinimumSeconds: Double
    public let edgePaddingSeconds: Double
    public let qualityGate: VoiceProfileQualityGate

    private struct ChunkMetrics {
        let startSeconds: Double
        let endSeconds: Double
        let speechActive: Bool
        let levelDB: Double
        let clippedFraction: Double
    }

    public init(
        targetMinimumSeconds: Double = 10.0,
        targetMaximumSeconds: Double = 20.0,
        preferredSeconds: Double = 15.0,
        absoluteMinimumSeconds: Double = VoiceProfile.minimumClipDuration,
        edgePaddingSeconds: Double = 0.25,
        qualityGate: VoiceProfileQualityGate = VoiceProfileQualityGate()
    ) {
        self.targetMinimumSeconds = targetMinimumSeconds
        self.targetMaximumSeconds = targetMaximumSeconds
        self.preferredSeconds = preferredSeconds
        self.absoluteMinimumSeconds = absoluteMinimumSeconds
        self.edgePaddingSeconds = edgePaddingSeconds
        self.qualityGate = qualityGate
    }

    public func trim(_ buffer: VoiceProfilePCMBuffer) -> VoiceProfileTrimResult {
        let originalDuration = buffer.durationSeconds
        guard buffer.sampleRate > 0, !buffer.samples.isEmpty else {
            return VoiceProfileTrimResult(
                buffer: buffer,
                startTimeSeconds: 0,
                endTimeSeconds: 0,
                originalDurationSeconds: 0,
                qualityReport: qualityGate.evaluate(buffer)
            )
        }

        if originalDuration <= absoluteMinimumSeconds {
            return VoiceProfileTrimResult(
                buffer: buffer,
                startTimeSeconds: 0,
                endTimeSeconds: originalDuration,
                originalDurationSeconds: originalDuration,
                qualityReport: qualityGate.evaluate(buffer)
            )
        }

        let chunks = analyzeChunks(buffer: buffer)
        let window: (start: Double, end: Double)
        if originalDuration <= targetMaximumSeconds {
            window = trimLeadingAndTrailingSilence(chunks: chunks, totalDuration: originalDuration)
        } else {
            window = bestSpeechWindow(chunks: chunks, totalDuration: originalDuration)
        }

        let sliced = buffer.sliced(from: window.start, to: window.end)
        let report = qualityGate.evaluate(sliced)
        return VoiceProfileTrimResult(
            buffer: sliced,
            startTimeSeconds: window.start,
            endTimeSeconds: min(originalDuration, window.start + sliced.durationSeconds),
            originalDurationSeconds: originalDuration,
            qualityReport: report
        )
    }

    private func analyzeChunks(buffer: VoiceProfilePCMBuffer) -> [ChunkMetrics] {
        let chunkLength = max(1, buffer.sampleRate / 10) // 100 ms chunks
        let chunkDuration = Double(chunkLength) / Double(buffer.sampleRate)
        var vad = HandsFreeEnergyVoiceActivityDetector(sensitivity: .medium)
        var chunks: [ChunkMetrics] = []

        var offset = 0
        while offset < buffer.samples.count {
            let end = min(buffer.samples.count, offset + chunkLength)
            let slice = buffer.samples[offset..<end]
            let update = vad.process(samples: slice, sampleRate: Double(buffer.sampleRate))

            var sumSquares = 0.0
            var clipped = 0
            for sample in slice {
                let value = Double(sample)
                sumSquares += value * value
                if abs(sample) >= qualityGate.clippingSampleThreshold {
                    clipped += 1
                }
            }
            let meanSquare = sumSquares / Double(max(1, slice.count))
            let levelDB = meanSquare > 1e-12 ? max(-100.0, 10.0 * log10(meanSquare)) : -100.0
            let isSpeech = (update?.speechDetected == true) || levelDB >= -42.0
            let startSeconds = Double(offset) / Double(buffer.sampleRate)
            let endSeconds = min(buffer.durationSeconds, startSeconds + chunkDuration)

            chunks.append(ChunkMetrics(
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                speechActive: isSpeech,
                levelDB: levelDB,
                clippedFraction: Double(clipped) / Double(max(1, slice.count))
            ))
            offset = end
        }
        return chunks
    }

    private func trimLeadingAndTrailingSilence(
        chunks: [ChunkMetrics],
        totalDuration: Double
    ) -> (start: Double, end: Double) {
        guard let firstSpeech = chunks.firstIndex(where: \.speechActive),
              let lastSpeech = chunks.lastIndex(where: \.speechActive) else {
            return (0, totalDuration)
        }
        var start = max(0, chunks[firstSpeech].startSeconds - edgePaddingSeconds)
        var end = min(totalDuration, chunks[lastSpeech].endSeconds + edgePaddingSeconds)

        let minimumLength = min(totalDuration, max(absoluteMinimumSeconds, min(targetMinimumSeconds, totalDuration)))
        if end - start < minimumLength {
            let deficit = minimumLength - (end - start)
            let expandBefore = min(start, deficit * 0.5)
            start -= expandBefore
            end = min(totalDuration, end + (deficit - expandBefore))
            if end - start < minimumLength {
                start = max(0, end - minimumLength)
            }
        }
        return (start, end)
    }

    private func bestSpeechWindow(
        chunks: [ChunkMetrics],
        totalDuration: Double
    ) -> (start: Double, end: Double) {
        let candidateLengths = [preferredSeconds, targetMaximumSeconds, targetMinimumSeconds]
            .filter { $0 <= totalDuration + 0.01 }
        let durations = candidateLengths.isEmpty ? [min(totalDuration, targetMaximumSeconds)] : candidateLengths

        var bestWindow = (start: 0.0, end: min(totalDuration, preferredSeconds))
        var bestScore = -Double.infinity
        let stepSeconds = 0.5

        for length in durations {
            let maxStart = max(0, totalDuration - length)
            var candidateStart = 0.0
            while candidateStart <= maxStart + 0.001 {
                let start = min(candidateStart, maxStart)
                let end = min(totalDuration, start + length)
                let score = scoreWindow(chunks: chunks, start: start, end: end)
                if score > bestScore {
                    bestScore = score
                    bestWindow = (start, end)
                }
                if maxStart == 0 { break }
                candidateStart += stepSeconds
            }
        }
        return bestWindow
    }

    private func scoreWindow(chunks: [ChunkMetrics], start: Double, end: Double) -> Double {
        let covered = chunks.filter { $0.endSeconds > start && $0.startSeconds < end }
        guard !covered.isEmpty else { return -Double.infinity }

        let speechRatio = Double(covered.filter(\.speechActive).count) / Double(covered.count)
        let clippingRatio = covered.map(\.clippedFraction).reduce(0, +) / Double(covered.count)

        let activeLevels = covered.filter(\.speechActive).map(\.levelDB).sorted()
        let quietLevels = covered.filter { !$0.speechActive }.map(\.levelDB).sorted()
        let speechMedian = activeLevels.isEmpty ? -60.0 : activeLevels[activeLevels.count / 2]
        let noiseMedian = quietLevels.isEmpty ? -65.0 : quietLevels[quietLevels.count / 2]
        let estimatedSNR = max(0, min(40, speechMedian - noiseMedian))

        let duration = end - start
        let durationBias = 1.0 - min(1.0, abs(duration - preferredSeconds) / 10.0)

        let edgeQuietBonus: Double = {
            let leadingQuiet = covered.first?.speechActive == false ? 0.5 : 0.0
            let trailingQuiet = covered.last?.speechActive == false ? 0.5 : 0.0
            return leadingQuiet + trailingQuiet
        }()

        // Penalise windows below 40% speech heavily so pure silence never wins over real speech.
        let lowSpeechPenalty = speechRatio < 0.4 ? -20.0 : 0.0

        return speechRatio * 10.0
            + estimatedSNR * 0.25
            - clippingRatio * 500.0
            + durationBias * 1.5
            + edgeQuietBonus
            + lowSpeechPenalty
    }
}
