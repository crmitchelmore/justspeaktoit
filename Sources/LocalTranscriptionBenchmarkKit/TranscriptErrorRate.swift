import Foundation

public enum TranscriptErrorRate {
    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        wordErrorRate(reference: reference, hypothesis: hypothesis, language: nil)
    }

    public static func wordErrorRate(
        reference: String,
        hypothesis: String,
        language: String?
    ) -> Double {
        let referenceWords = wordUnits(reference, language: language)
        let hypothesisWords = wordUnits(hypothesis, language: language)
        return rate(reference: referenceWords, hypothesis: hypothesisWords)
    }

    public static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let referenceCharacters = normalizedCharacters(reference)
        let hypothesisCharacters = normalizedCharacters(hypothesis)
        return rate(reference: referenceCharacters, hypothesis: hypothesisCharacters)
    }

    public static func aggregateWordErrorRate(
        _ measurements: [LocalTranscriptionBenchmarkMeasurement]
    ) -> Double {
        var edits = 0
        var referenceCount = 0
        for measurement in measurements {
            let reference = wordUnits(
                measurement.referenceTranscript,
                language: measurement.language
            )
            edits += editDistance(
                reference,
                wordUnits(measurement.transcript, language: measurement.language)
            )
            referenceCount += reference.count
        }
        guard referenceCount > 0 else {
            return measurements.allSatisfy {
                wordUnits($0.transcript, language: $0.language).isEmpty
            } ? 0 : 1
        }
        return Double(edits) / Double(referenceCount)
    }

    public static func aggregateCharacterErrorRate(
        _ measurements: [LocalTranscriptionBenchmarkMeasurement]
    ) -> Double {
        aggregateRate(measurements, units: normalizedCharacters)
    }

    public static func normalizedWords(_ text: String) -> [String] {
        normalizedText(text).split(separator: " ").map(String.init)
    }

    public static func normalizedCharacters(_ text: String) -> [Character] {
        Array(normalizedText(text).filter { !$0.isWhitespace })
    }

    private static func wordUnits(_ text: String, language: String?) -> [String] {
        let code = language?
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first?
            .lowercased()
        if let code, ["zh", "ja", "ko", "th"].contains(code) {
            return normalizedCharacters(text).map(String.init)
        }
        return normalizedWords(text)
    }

    private static func normalizedText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                return Character(String(scalar))
            }
            return " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func aggregateRate<Unit: Equatable>(
        _ measurements: [LocalTranscriptionBenchmarkMeasurement],
        units: (String) -> [Unit]
    ) -> Double {
        var edits = 0
        var referenceCount = 0
        for measurement in measurements {
            let reference = units(measurement.referenceTranscript)
            edits += editDistance(reference, units(measurement.transcript))
            referenceCount += reference.count
        }
        guard referenceCount > 0 else {
            return measurements.allSatisfy { units($0.transcript).isEmpty } ? 0 : 1
        }
        return Double(edits) / Double(referenceCount)
    }

    private static func rate<Unit: Equatable>(reference: [Unit], hypothesis: [Unit]) -> Double {
        guard !reference.isEmpty else { return hypothesis.isEmpty ? 0 : 1 }
        return Double(editDistance(reference, hypothesis)) / Double(reference.count)
    }

    private static func editDistance<Unit: Equatable>(_ lhs: [Unit], _ rhs: [Unit]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }

        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(rhs.count + 1)
            for (rightIndex, right) in rhs.enumerated() {
                let substitution = previous[rightIndex] + (left == right ? 0 : 1)
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
