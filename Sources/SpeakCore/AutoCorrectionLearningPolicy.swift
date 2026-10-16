import Foundation

public enum AutoCorrectionLearningPolicy {
    public static let enabledByDefault = true
    public static let defaultPromotionThreshold = 2
    public static let promotionThresholdRange = 2...10
    public static let maximumUTF16Units = 8_192
    public static var numericPromotionThresholdRange: ClosedRange<Double> {
        let range = Self.promotionThresholdRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }

    public static func observationSeconds(for text: String) -> Double {
        min(10 + Double(sentenceCount(in: text)), 30)
    }

    public static func sentenceCount(in text: String) -> Int {
        let enders = CharacterSet(charactersIn: ".!?")
        return text.unicodeScalars.filter { enders.contains($0) }.count
    }
}
