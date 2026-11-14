#if os(iOS)
import Foundation
import SpeakCore

/// Learned auto-corrections (F48, #1651). The keyboard reads the enabled flag
/// from the App Group, so every change is mirrored there.
extension AppSettings {
    static func storedAutoCorrectionsEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: DefaultsKey.autoCorrectionsEnabled.rawValue) as? Bool
            ?? AutoCorrectionLearningPolicy.enabledByDefault
    }

    static func storedAutoCorrectionsPromotionThreshold(in defaults: UserDefaults) -> Int {
        let stored = defaults.object(forKey: DefaultsKey.autoCorrectionsPromotionThreshold.rawValue) as? Int
            ?? AutoCorrectionLearningPolicy.defaultPromotionThreshold
        return clampedPromotionThreshold(stored)
    }

    static func clampedPromotionThreshold(_ value: Int) -> Int {
        let range = AutoCorrectionLearningPolicy.promotionThresholdRange
        return min(max(value, range.lowerBound), range.upperBound)
    }

    func persistAutoCorrectionsEnabled() {
        defaults.set(autoCorrectionsEnabled, forKey: DefaultsKey.autoCorrectionsEnabled.rawValue)
        KeyboardCorrectionStore.shared.setLearningEnabled(autoCorrectionsEnabled)
    }

    func persistAutoCorrectionsPromotionThreshold() {
        let clamped = Self.clampedPromotionThreshold(autoCorrectionsPromotionThreshold)
        guard clamped == autoCorrectionsPromotionThreshold else {
            autoCorrectionsPromotionThreshold = clamped
            return
        }
        defaults.set(clamped, forKey: DefaultsKey.autoCorrectionsPromotionThreshold.rawValue)
    }
}
#endif
