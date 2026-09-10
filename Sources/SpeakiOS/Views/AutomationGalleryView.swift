#if os(iOS)
import AppIntents
import SpeakCore
import SwiftUI

/// The Shortcuts gallery (issue #1015).
///
/// Recipes rather than downloads. A hosted `.shortcut` file has to be signed
/// again for every iOS release and fails to install silently when it is not,
/// which teaches the user the feature is broken; a recipe the user builds from
/// named actions cannot rot that way, and every action it names is one this
/// app ships and tests (`AutomationGalleryIntentTests`).
struct AutomationGalleryView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                Text(
                    "Shortcuts is how a transcript reaches Notes, Reminders, Messages or Mail "
                        + "without the app coming to the front. Build any of these once and bind "
                        + "it to the Action Button, Back Tap, a Control or Siri."
                )
                    .font(.callout)

                ShortcutsLink()
                    .shortcutsLinkStyle(.automatic)
                    .accessibilityIdentifier("automationGalleryShortcutsLink")
            }

            ForEach(AutomationGallery.recipes) { recipe in
                Section {
                    recipeHeader(recipe)
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                        if step.startsNewShortcut {
                            Text("In a second shortcut")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        stepRow(index: index + 1, step: step)
                    }
                    ForEach(recipe.requirements, id: \.self) { requirement in
                        Label(requirement, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Siri") {
                if #available(iOS 18.0, *) {
                    SiriTipView(intent: DictateIntent(), isVisible: .constant(true))
                        .listRowInsets(EdgeInsets())
                }
                Text(
                    "Every action with a phrase can be spoken. \"Dictate with Just Speak to It\" "
                        + "records and hands the text back; \"Get my last transcription from "
                        + "Just Speak to It\" reads out the most recent one."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shortcuts Gallery")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func recipeHeader(_ recipe: AutomationRecipe) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(recipe.title, systemImage: recipe.systemImage)
                .font(.headline)
            Text(recipe.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("automationRecipe.\(recipe.id)")
    }

    private func stepRow(index: Int, step: AutomationRecipeStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .font(.subheadline.weight(.medium))
                    // Says which steps this app is answerable for and which
                    // belong to Apple, so a missing system action is not read
                    // as a broken Just Speak to It action.
                    Text(step.isAppAction ? "Just Speak to It" : "Built in")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (step.isAppAction ? Color.accentColor : Color.secondary)
                                .opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(.secondary)
                }
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
