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
    HStack(spacing: settings.visualDensity.groupSpacing) {
      Label("Settings", systemImage: "slider.horizontal.3")
        .font(.subheadline.bold())
        .lineLimit(1)

      Spacer(minLength: 4)

      compactOverviewMetric(
        title: "Mode",
        value: overviewModeValue,
        systemImage: "waveform"
      )
      compactOverviewMetric(
        title: settings.isActiveAssemblyAILiveModel ? "Pre-processing" : "Post-processing",
        value: overviewPostProcessingValue,
        systemImage: "wand.and.stars"
      )
      compactOverviewMetric(
        title: "Output",
        value: settings.textOutputMethod.displayName,
        systemImage: "text.alignleft"
      )
      compactOverviewMetric(
        title: "OpenRouter Key",
        value: isOpenRouterKeyStored ? "Stored" : "Missing",
        systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill"
      )
    }
    .padding(settings.visualDensity.cardPadding)
    .foregroundStyle(.white)
    .background(
      LinearGradient(
        colors: [Color.orange, Color.orange.opacity(0.72)],
        startPoint: .leading,
        endPoint: .trailing
      ),
      in: RoundedRectangle(
        cornerRadius: settings.visualDensity.cardCornerRadius,
        style: .continuous
      )
    )
  }

  private func compactOverviewMetric(
    title: String,
    value: String,
    systemImage: String
  ) -> some View {
    Label(value, systemImage: systemImage)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .accessibilityLabel("\(title): \(value)")
  }

  private var normalOverviewHeader: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .center) {
        Image(systemName: "sparkles.rectangle.stack")
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .white.opacity(0.7))
          .font(.system(size: 34, weight: .semibold))
          .frame(width: 56, height: 56)
          .background(
            Color.orange.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous))

        VStack(alignment: .leading, spacing: 6) {
          Text("Tune Speak to match your flow")
            .font(.title2.bold())
            .foregroundStyle(.white)
          Text(
            "Choose recording modes, manage keys, and keep permissions in sync—all in one place."
          )
          .font(.callout)
          .foregroundStyle(.white.opacity(0.8))
        }
        Spacer()
      }

      HStack(spacing: 16) {
        overviewChip(
          title: "Mode", value: overviewModeValue, systemImage: "waveform")
        overviewChip(
          title: settings.isActiveAssemblyAILiveModel ? "Pre-processing" : "Post-processing",
          value: overviewPostProcessingValue,
          systemImage: "wand.and.stars")
        overviewChip(
          title: "Output", value: settings.textOutputMethod.displayName,
          systemImage: "text.alignleft")
        overviewChip(
          title: "OpenRouter Key", value: isOpenRouterKeyStored ? "Stored" : "Missing",
          systemImage: isOpenRouterKeyStored ? "checkmark.seal.fill" : "key.fill")
      }
    }
    .padding(24)
    .background(
      LinearGradient(
        colors: [Color.orange, Color.orange.opacity(0.7)], startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      .cornerRadius(24)
      .shadow(color: Color.orange.opacity(0.3), radius: 18, x: 0, y: 12)
    )
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

  private func overviewChip(title: String, value: String, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.white.opacity(0.8))
      Text(value)
        .font(.headline)
        .foregroundStyle(.white)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}
