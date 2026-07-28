import SpeakCore
import SwiftUI

struct SpeakDensityCard<Content: View>: View {
  @Environment(\.appVisualDensity) private var density
  let title: String
  let systemImage: String
  let tint: Color
  let regularCornerRadius: CGFloat
  let regularSpacerMinLength: CGFloat
  @ViewBuilder let content: Content

  init(
    title: String,
    systemImage: String,
    tint: Color,
    regularCornerRadius: CGFloat = 28,
    regularSpacerMinLength: CGFloat = 0,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
    self.regularCornerRadius = regularCornerRadius
    self.regularSpacerMinLength = regularSpacerMinLength
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: density.cardContentSpacing) {
      HStack(spacing: density.isCompact ? density.inlineSpacing : 14) {
        cardIcon
        Text(title)
          .font(density.isCompact ? .caption.weight(.semibold) : .headline)
          .foregroundStyle(.primary)
        Spacer(minLength: density.isCompact ? 0 : regularSpacerMinLength)
      }

      content
    }
    .padding(density.cardPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .ultraThinMaterial,
      in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .stroke(tint.opacity(0.12), lineWidth: 1)
        .allowsHitTesting(false)
    )
    .shadow(
      color: tint.opacity(density.isCompact ? 0 : 0.08),
      radius: density.isCompact ? 0 : 18,
      x: 0,
      y: density.isCompact ? 0 : 12
    )
  }

  @ViewBuilder
  private var cardIcon: some View {
    if density.isCompact {
      Image(systemName: systemImage)
        .foregroundStyle(tint)
        .font(.caption.weight(.semibold))
        .frame(width: 16)
    } else {
      ZStack {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(tint.opacity(0.15))
          .frame(width: 44, height: 44)
        Image(systemName: systemImage)
          .foregroundStyle(tint)
          .font(.system(size: 20, weight: .semibold))
      }
    }
  }

  private var cornerRadius: CGFloat {
    density.isCompact ? density.cardCornerRadius : regularCornerRadius
  }
}
