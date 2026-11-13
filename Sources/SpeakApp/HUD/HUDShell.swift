import SwiftUI

/// The rounded background and outline of the full HUD. It owns the choice
/// between Liquid Glass, the reduced-transparency fill, the legacy fill and
/// the default material, so the content view only decides what to show.
struct HUDShell: ViewModifier {
  let style: HUDPhaseStyle
  let usesLegacyRendering: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    #if compiler(>=6.1) && canImport(SwiftUI, _version: 7.0)
    if #available(macOS 26.0, *), HUDPlatformWorkarounds.isGlassEffectEnabled, !reduceTransparency {
      content
        .background(style.tint)
        .glassEffect(.regular.tint(style.color.opacity(0.18)).interactive(), in: .rect(cornerRadius: 20))
        .overlay(shape.stroke(style.color.opacity(0.35), lineWidth: style.strokeWidth))
    } else {
      fallback(content, shape: shape)
    }
    #else
    fallback(content, shape: shape)
    #endif
  }

  @ViewBuilder
  private func fallback(_ content: Content, shape: RoundedRectangle) -> some View {
    if reduceTransparency {
      content
        .background(
          shape
            .fill(colorScheme == .dark ? Color.black : Color.white)
            .overlay(style.tint)
        )
        .overlay(shape.stroke(style.color.opacity(0.45), lineWidth: style.strokeWidth))
    } else if usesLegacyRendering {
      content
        .background(
          shape
            .fill(colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.94))
            .overlay(style.tint)
        )
        .overlay(shape.stroke(style.color.opacity(0.28), lineWidth: style.strokeWidth))
    } else {
      content
        .background(
          shape
            .fill(.thickMaterial)
            .overlay(style.tint)
        )
        .overlay(shape.stroke(style.color.opacity(0.45), lineWidth: style.strokeWidth))
    }
  }
}
