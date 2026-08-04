import SpeakCore
import SwiftUI

struct LocaleOption: Identifiable, Equatable {
  let displayName: String
  let identifier: String
  var id: String { identifier }
}

struct SettingsInlineInfo: View {
  @Environment(\.appVisualDensity) var density
  let title: String
  let message: String
  let systemImage: String

  var body: some View {
    HStack(alignment: .top, spacing: density.isCompact ? density.inlineSpacing : 10) {
      Image(systemName: systemImage)
        .foregroundStyle(Color.brandLagoon)
        .frame(width: density.isCompact ? 14 : 20)
      VStack(alignment: .leading, spacing: density.isCompact ? 1 : 3) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(message)
          .font(density.isCompact ? .caption2 : .caption)
          .foregroundStyle(.secondary)
          .lineLimit(density.isCompact ? 1 : nil)
      }
    }
    .padding(density.isCompact ? 6 : 12)
    .background(
      RoundedRectangle(cornerRadius: density.isCompact ? 7 : 12, style: .continuous)
        .fill(Color.brandLagoon.opacity(0.08))
    )
    .speakTooltip(message)
  }
}

struct SettingsCard<Content: View>: View {
  let title: String
  let systemImage: String
  let tint: Color
  @ViewBuilder let content: Content

  init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.content = content()
  }

  var body: some View {
    SpeakDensityCard(
      title: title,
      systemImage: systemImage,
      tint: tint,
      regularCornerRadius: 26,
      regularSpacerMinLength: 8
    ) {
      content
    }
  }
}

struct TranscriptionModeSegmentedPickerStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .pickerStyle(.segmented)
      .frame(minWidth: 260, idealWidth: 320, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(nsColor: .controlBackgroundColor))
      )
  }
}
