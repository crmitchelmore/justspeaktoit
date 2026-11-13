import SpeakCore
import SwiftUI

/// The banner above every settings tab summarising mode, post-processing,
/// output and the OpenRouter key.
struct SettingsOverviewHeader: View {
  @EnvironmentObject var settings: AppSettings
  let isOpenRouterKeyStored: Bool

  @ViewBuilder
  var body: some View {
    if settings.visualDensity.isCompact {
      compactOverviewHeader
    } else {
      normalOverviewHeader
    }
  }

  private var compactOverviewHeader: some View {
    PageHeroStrip("Settings", systemImage: "slider.horizontal.3", palette: .settings) {
      Spacer(minLength: 4)
      ForEach(overviewFigures, id: \.title) { figure in
        CompactHeroMetric(title: figure.title, value: figure.value, systemImage: figure.systemImage)
      }
    }
  }

  private var normalOverviewHeader: some View {
    PageHeroHeader(
      "Tune Speak to match your flow",
      subtitle: "Choose recording modes, manage keys, and keep permissions in sync—all in one place.",
      palette: .settings
    ) {
      HStack(spacing: 16) {
        ForEach(overviewFigures, id: \.title) { figure in
          HeroStatChip(title: figure.title, value: figure.value, systemImage: figure.systemImage)
        }
      }
    }
  }

  private var overviewFigures: [HeroFigure] {
    [
      HeroFigure(title: "Mode", value: overviewModeValue, systemImage: "waveform"),
      HeroFigure(
        title: settings.isActiveAssemblyAILiveModel ? "Pre-processing" : "Post-processing",
        value: overviewPostProcessingValue,
        systemImage: "wand.and.stars"
      ),
      HeroFigure(title: "Output", value: settings.textOutputMethod.displayName, systemImage: "text.alignleft"),
      HeroFigure(
        title: "OpenRouter Key",
        value: isOpenRouterKeyStored ? "Stored" : "Missing",
        systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill"
      )
    ]
  }

  private var overviewModeValue: String {
    settings.effectiveTranscriptionModeDisplayName
  }

  private var overviewPostProcessingValue: String {
    if settings.isActiveAssemblyAILiveModel {
      return "Keyterms only"
    }
    guard settings.postProcessingEnabled, settings.speedMode == .instant else {
      return "Disabled"
    }
    return PostProcessingManager.isLocalPostProcessingModel(settings.postProcessingModel)
      ? "Local"
      : "Remote"
  }
}
