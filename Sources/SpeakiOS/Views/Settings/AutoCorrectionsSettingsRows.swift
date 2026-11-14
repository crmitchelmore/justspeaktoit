#if os(iOS)
import SpeakCore
import SwiftUI

/// The Auto-Corrections section rows (F48, #1651): the learning toggle, the
/// promotion threshold and the way into learned corrections.
struct AutoCorrectionsSettingsRows: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var engine = IOSLearnedCorrections.shared.engine
    @ObservedObject private var lexicon = IOSLearnedCorrections.shared.lexicon

    var body: some View {
        Toggle(isOn: $settings.autoCorrectionsEnabled) {
            Label("Learn Corrections Automatically", systemImage: "text.badge.checkmark")
        }
        .accessibilityLabel("Learn corrections automatically")
        .accessibilityIdentifier("autoCorrectionsToggle")

        if settings.autoCorrectionsEnabled {
            Stepper(
                "Promote after \(settings.autoCorrectionsPromotionThreshold) edits",
                value: $settings.autoCorrectionsPromotionThreshold,
                in: AutoCorrectionLearningPolicy.promotionThresholdRange
            )
            .accessibilityLabel("Promotion threshold")
            .accessibilityValue("\(settings.autoCorrectionsPromotionThreshold) occurrences")
            .accessibilityIdentifier("autoCorrectionsThresholdStepper")
        }

        NavigationLink {
            LearnedCorrectionsView()
        } label: {
            SettingsValueLabel(title: "Learned Corrections", systemImage: "list.bullet", value: summary)
        }
        .accessibilityIdentifier("learnedCorrectionsLink")

        SettingsFootnote(
            "Learns from words you change after the Just Speak Keyboard inserts a transcript. "
                + "Only the changed words are kept, on \(DeviceCopy.thisDevice). "
                + "Learned corrections keep applying until you remove them."
        )
    }

    private var summary: String {
        let rules = lexicon.rules.filter { $0.source == .automatic }.count
        let candidates = engine.candidates.count
        return "\(rules) learned, \(candidates) candidate\(candidates == 1 ? "" : "s")"
    }
}
#endif
