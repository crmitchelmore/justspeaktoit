import Foundation

extension VoiceProfileQualityGate {
    func analyzeFrames(in samples: [Float], sampleRate: Int) -> FrameAnalysis {
        guard sampleRate > 0, !samples.isEmpty else {
            return FrameAnalysis(
                hopSeconds: 0.02, activeSeconds: 0, activityRatio: 0,
                peakFrameDB: -100, estimatedSNRDB: 0, voicedPitchSemitones: []
            )
        }
        let hopLength = max(1, sampleRate / 50) // 20 ms hop
        let windowLength = max(hopLength, (sampleRate * 3) / 100) // 30 ms window for pitch lag coverage
        let hopSeconds = Double(hopLength) / Double(sampleRate)
        let lagMin = max(1, Int((Double(sampleRate) / 380.0).rounded()))
        let lagMax = max(lagMin, Int((Double(sampleRate) / 70.0).rounded()))

        var frameDBs: [Double] = []
        var activeCorrelations: [Double] = []
        var voicedSemitones: [Double] = []
        var activeCount = 0
        var peakDB = -100.0

        var start = 0
        while start + hopLength <= samples.count {
            let end = min(samples.count, start + windowLength)
            let level = frameRMSDB(samples: samples, start: start, end: start + hopLength)
            frameDBs.append(level)
            if level > peakDB { peakDB = level }
            if level >= -45.0 {
                activeCount += 1
                let pitch = pitchAutocorrelation(
                    samples: samples, start: start, end: end, lagMin: lagMin, lagMax: lagMax
                )
                activeCorrelations.append(pitch.correlation)
                if pitch.correlation >= 0.55, pitch.lag > 0 {
                    let hertz = Double(sampleRate) / Double(pitch.lag)
                    voicedSemitones.append(12.0 * log2(hertz / 100.0))
                }
            }
            start += hopLength
        }

        let totalFrames = max(1, frameDBs.count)
        let activeSeconds = Double(activeCount) * hopSeconds
        let activityRatio = Double(activeCount) / Double(totalFrames)
        let estimatedSNR = estimateSNR(frameDBs: frameDBs, activeCorrelations: activeCorrelations)
        return FrameAnalysis(
            hopSeconds: hopSeconds,
            activeSeconds: activeSeconds,
            activityRatio: activityRatio,
            peakFrameDB: peakDB,
            estimatedSNRDB: estimatedSNR,
            voicedPitchSemitones: voicedSemitones
        )
    }

    func detectsMultipleSpeakers(pitchSemitones: [Double], hopSeconds: Double) -> Bool {
        guard pitchSemitones.count >= 20 else { return false }
        let sorted = pitchSemitones.sorted()
        guard let initialLow = percentile(sorted, fraction: 0.15),
              let initialHigh = percentile(sorted, fraction: 0.85),
              abs(initialHigh - initialLow) >= minimumSpeakerSeparationSemitones * 0.6 else {
            return false
        }

        var centerLow = initialLow
        var centerHigh = initialHigh
        var clusterLow: [Double] = []
        var clusterHigh: [Double] = []

        for _ in 0..<12 {
            clusterLow.removeAll(keepingCapacity: true)
            clusterHigh.removeAll(keepingCapacity: true)
            for value in pitchSemitones {
                if abs(value - centerLow) <= abs(value - centerHigh) {
                    clusterLow.append(value)
                } else {
                    clusterHigh.append(value)
                }
            }
            guard !clusterLow.isEmpty, !clusterHigh.isEmpty else { return false }
            centerLow = clusterLow.reduce(0, +) / Double(clusterLow.count)
            centerHigh = clusterHigh.reduce(0, +) / Double(clusterHigh.count)
        }

        let minClusterSize = min(clusterLow.count, clusterHigh.count)
        let ratio = Double(minClusterSize) / Double(pitchSemitones.count)
        let secondarySeconds = Double(minClusterSize) * hopSeconds
        guard ratio >= minimumSecondarySpeakerRatio, secondarySeconds >= minimumSecondarySpeakerSeconds else {
            return false
        }

        let medianLow = percentile(clusterLow.sorted(), fraction: 0.50) ?? centerLow
        let medianHigh = percentile(clusterHigh.sorted(), fraction: 0.50) ?? centerHigh
        let separation = abs(medianHigh - medianLow)
        let varianceLow = variance(of: clusterLow, mean: centerLow)
        let varianceHigh = variance(of: clusterHigh, mean: centerHigh)
        let fisherRatio = separation / sqrt(varianceLow + varianceHigh + 0.25)

        return separation >= minimumSpeakerSeparationSemitones && fisherRatio >= minimumBimodalFisherRatio
    }

    private func frameRMSDB(samples: [Float], start: Int, end: Int) -> Double {
        let count = end - start
        guard count > 0 else { return -100 }
        var sumSquares = 0.0
        for index in start..<end {
            let value = Double(samples[index].isFinite ? samples[index] : 0)
            sumSquares += value * value
        }
        let meanSquare = sumSquares / Double(count)
        guard meanSquare > 1e-12 else { return -100 }
        return max(-100.0, 10.0 * log10(meanSquare))
    }

    private func pitchAutocorrelation(
        samples: [Float],
        start: Int,
        end: Int,
        lagMin: Int,
        lagMax: Int
    ) -> (lag: Int, correlation: Double) {
        let count = end - start
        let upperLag = min(lagMax, count - 16)
        guard upperLag >= lagMin else { return (0, 0) }
        var correlations = [Double](repeating: 0, count: upperLag + 1)
        var bestLag = 0
        var bestCorrelation = 0.0

        for lag in lagMin...upperLag {
            let correlation = normalizedAutocorrelation(samples: samples, start: start, count: count, lag: lag)
            correlations[lag] = correlation
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }
        return firstFundamentalPeak(
            correlations: correlations,
            lagMin: lagMin,
            upperLag: upperLag,
            fallback: (bestLag, bestCorrelation)
        )
    }

    private func normalizedAutocorrelation(samples: [Float], start: Int, count: Int, lag: Int) -> Double {
        let overlap = count - lag
        var cross = 0.0
        var energyA = 0.0
        var energyB = 0.0
        for offset in 0..<overlap {
            let first = Double(samples[start + offset])
            let second = Double(samples[start + offset + lag])
            cross += first * second
            energyA += first * first
            energyB += second * second
        }
        let denominator = sqrt(energyA * energyB)
        return denominator > 1e-12 ? cross / denominator : 0
    }

    private func firstFundamentalPeak(
        correlations: [Double],
        lagMin: Int,
        upperLag: Int,
        fallback: (lag: Int, correlation: Double)
    ) -> (lag: Int, correlation: Double) {
        // Pick the shortest-lag local peak near the global max so periodic speech does not lock onto 2x/3x lags.
        guard fallback.correlation > 0 else { return (0, 0) }
        let threshold = fallback.correlation * 0.95
        for lag in lagMin...upperLag {
            let value = correlations[lag]
            let prev = lag > lagMin ? correlations[lag - 1] : 0
            let next = lag < upperLag ? correlations[lag + 1] : 0
            if value >= threshold, value >= prev, value >= next {
                return (lag, value)
            }
        }
        return fallback
    }

    private func estimateSNR(frameDBs: [Double], activeCorrelations: [Double]) -> Double {
        guard !frameDBs.isEmpty else { return 0 }
        let sortedCorrelations = activeCorrelations.sorted()
        let p75Corr = percentile(sortedCorrelations, fraction: 0.75) ?? 0
        // Reject unvoiced broadband noise bursts that contain no periodic vocal harmonics.
        if !sortedCorrelations.isEmpty, p75Corr < 0.35 {
            return 0
        }

        let sortedDB = frameDBs.sorted()
        let lowSpread = (percentile(sortedDB, fraction: 0.90) ?? -100)
            - (percentile(sortedDB, fraction: 0.10) ?? -100)
        if lowSpread >= 4.0 {
            let speechLevel = percentile(sortedDB, fraction: 0.85) ?? -100
            let pauseFrames = sortedDB.filter { $0 < speechLevel - 10.0 }
            if pauseFrames.count >= 5 {
                let floor = percentile(pauseFrames, fraction: 0.50) ?? -100
                return max(0, speechLevel - floor)
            }
            let bottomFloor = percentile(sortedDB, fraction: 0.10) ?? -100
            return max(0, speechLevel - bottomFloor)
        }

        // Stationary energy without pauses: use median harmonicity to separate clean continuous speech from noise.
        let medianCorr = percentile(sortedCorrelations, fraction: 0.50) ?? 0
        guard medianCorr > 0.35 else { return 0 }
        let clamped = min(0.999, max(0.01, medianCorr))
        return max(0, 10.0 * log10(clamped / (1.0 - clamped)))
    }

    private func variance(of values: [Double], mean: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0.0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        }
        return sum / Double(values.count)
    }

    private func percentile(_ sorted: [Double], fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let clamped = max(0, min(1, fraction))
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(position)
        let upper = min(sorted.count - 1, lower + 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
