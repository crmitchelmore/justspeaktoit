import Foundation
import SpeakCore
import SwiftUI

// swiftlint:disable type_body_length file_length
struct HUDOverlay: View {
  @ObservedObject var manager: HUDManager
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    if manager.snapshot.phase.isVisible {
      presentedContent
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .accessibilityIdentifier("hudOverlay")
    }
  }

  @ViewBuilder
  private var presentedContent: some View {
    if shouldUseLegacyRendering || reduceMotion {
      content
    } else {
      content
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
  }

  private var content: some View {
    let base = VStack(spacing: 12) {
      animatedGlyph
        .accessibilityHidden(false)
      VStack(spacing: 4) {
        Text(manager.snapshot.headline)
          .font(.headline)
          .foregroundStyle(headlineColor)
          .dynamicTypeSize(...DynamicTypeSize.accessibility1)
          .accessibilityLabel("Status: \(manager.snapshot.headline)")
          .accessibilityAddTraits(.isHeader)
        if let sub = manager.snapshot.subheadline {
          Text(sub)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityLabel(sub)
        }
        if manager.snapshot.showRetryHint {
          Text("Press ⌘R to retry")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .accessibilityHint("Press Command-R to retry the operation")
        }
      }
      .accessibilityElement(children: .combine)
      if case .recording = manager.snapshot.phase {
        AudioLevelMeterView(
          level: manager.audioLevel,
          animatesLevel: !shouldUseLegacyRendering && !reduceMotion,
          width: 100,
          height: 4
        )
          .padding(.top, 2)
          .accessibilityLabel("Audio level meter")
          .accessibilityValue("\(Int(manager.audioLevel * 100)) percent")
          .accessibilityAddTraits(.updatesFrequently)
      }
      if manager.snapshot.phase.isTerminal == false {
        Text(elapsedText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("Elapsed time: \(elapsedText)")
          .accessibilityAddTraits(.updatesFrequently)
      }

      // Live transcript section (recording and voice-edit listening phases with content)
      if manager.snapshot.phase == .recording || manager.snapshot.phase == .editing,
         settings.showLiveTranscriptInHUD {
        transcriptSection
      }

      // Capture health row: shown during recording and failure phases.
      switch manager.snapshot.phase {
      case .recording, .failure:
        captureHealthRow
          .padding(.top, 4)
      default:
        EmptyView()
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .accessibilityElement(children: .contain)
    .accessibilitySortPriority(1)
    let shell = hudShell(base)
      .frame(maxWidth: hudMaxWidth)
      .padding(.horizontal, 60)
      .accessibilityAddTraits(.isModal)
    if shouldUseLegacyRendering || reduceMotion {
      return AnyView(shell)
    } else {
      return AnyView(
        shell
          .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 12)
          .animation(.spring(response: 0.25, dampingFraction: 0.85), value: manager.snapshot.phase)
          .animation(.spring(response: 0.25, dampingFraction: 0.85), value: manager.isExpanded)
      )
    }
  }

  @ViewBuilder
  private func hudShell<Content: View>(_ view: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    #if compiler(>=6.1) && canImport(SwiftUI, _version: 7.0)
    if #available(macOS 26.0, *), HUDPlatformWorkarounds.isGlassEffectEnabled, !reduceTransparency {
      view
        .background(phaseTint)
        .glassEffect(.regular.tint(phaseColor.opacity(0.18)).interactive(), in: .rect(cornerRadius: 20))
        .overlay(shape.stroke(phaseColor.opacity(0.35), lineWidth: strokeWidth))
    } else {
      hudShellFallback(view, shape: shape)
    }
    #else
    hudShellFallback(view, shape: shape)
    #endif
  }

  @ViewBuilder
  private func hudShellFallback<Content: View>(_ view: Content, shape: RoundedRectangle) -> some View {
    if reduceTransparency {
      view
        .background(
          shape
            .fill(opaqueBackgroundColor)
            .overlay(phaseTint)
        )
        .overlay(shape.stroke(phaseColor.opacity(0.45), lineWidth: strokeWidth))
    } else if shouldUseLegacyRendering {
      view
        .background(
          shape
            .fill(legacyBackgroundColor)
            .overlay(phaseTint)
        )
        .overlay(shape.stroke(phaseColor.opacity(0.28), lineWidth: strokeWidth))
    } else {
      view
        .background(
          shape
            .fill(.thickMaterial)
            .overlay(phaseTint)
        )
        .overlay(shape.stroke(phaseColor.opacity(0.45), lineWidth: strokeWidth))
    }
  }

  @ViewBuilder
  private func liveTranscriptionView(text: String) -> some View {
    let isFinal = manager.snapshot.liveTextIsFinal
    let confidence = manager.snapshot.liveTextConfidence

    HStack(spacing: 6) {
      ZStack(alignment: .top) {
        // Invisible two-line template reserves a fixed height so the HUD
        // doesn't reflow every time streamed text wraps from one line to two.
        Text(verbatim: " \n ")
          .font(.callout)
          .hidden()
        Text(text)
          .font(isFinal ? .callout : .callout.italic())
          .fontWeight(isFinal ? .regular : .light)
          .foregroundStyle(isFinal ? .primary : .secondary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
          .truncationMode(.head)
          .animation(
            (shouldUseLegacyRendering || reduceMotion) ? nil : .easeInOut(duration: 0.2),
            value: isFinal
          )
          .accessibilityLabel(isFinal ? "Transcript: \(text)" : "Partial transcript: \(text)")
      }

      if let confidence, confidence > 0 {
        Text("\(Int(confidence * 100))%")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .background(
            Capsule()
              .fill(.quaternary)
          )
          .accessibilityLabel("Confidence: \(Int(confidence * 100)) percent")
      }
    }
  }

  @ViewBuilder
  private var transcriptSection: some View {
    let transcriptText = manager.snapshot.liveText ?? ""
    if !transcriptText.isEmpty {
      // Show the live transcript inline (no disclosure/expand UI).
      liveTranscriptionView(text: transcriptText)
        .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var captureHealthRow: some View {
    let health = manager.captureHealth
    let micWarning = health.noInputDevicesAvailable || health.microphonePermission == .denied
    // Use higher contrast for warning state to meet WCAG AA.
    let micColor: Color = micWarning
      ? (colorScheme == .dark ? Color.red.opacity(0.9) : Color.red)
      : .secondary
    let microphonePermissionLabel = {
      if health.noInputDevicesAvailable {
        return "No device"
      }
      switch health.microphonePermission {
      case .granted:
        return "Granted"
      case .denied:
        return "Denied"
      default:
        return "Unknown"
      }
    }()
    let micIcon = micWarning ? "mic.slash.fill" : "mic.fill"
    let deviceLabel = health.noInputDevicesAvailable ? "No microphone connected" : health.inputDeviceName
    HStack(spacing: 6) {
      HStack(spacing: 4) {
        Image(systemName: micIcon)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(micColor)
          .accessibilityLabel("Microphone: \(microphonePermissionLabel)")

        Text(deviceLabel)
          .font(.caption2)
          .foregroundStyle(health.noInputDevicesAvailable ? micColor : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(deviceLabel)
          .accessibilityLabel("Input device: \(deviceLabel)")
      }

      Text(verbatim: "·")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

      Text(health.providerLabel)
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
        .help(health.providerLabel)
        .accessibilityLabel("Transcription provider: \(health.providerLabel)")

      LatencyBadgeCompact(tier: health.latencyTier, emphasized: true)
        .layoutPriority(2)
        .accessibilityLabel("Latency: \(health.latencyTier.displayName)")
    }
    .frame(height: 18)
    .accessibilityElement(children: .combine)
  }

  private var phaseColor: Color {
    switch manager.snapshot.phase {
    case .armed:
      return .brandLagoon
    case .recording:
      return .red
    case .transcribing:
      return .brandLagoon
    case .postProcessing:
      return .brandAccent
    case .delivering:
      return .green
    case .editing:
      return .brandAccentWarm
    case .success:
      return .green
    case .failure:
      return .red
    case .hidden:
      return .gray
    }
  }

  private var headlineColor: Color {
    switch manager.snapshot.phase {
    case .failure:
      return phaseColor
    default:
      return .primary
    }
  }

  @ViewBuilder
  private var phaseTint: some View {
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    switch manager.snapshot.phase {
    case .failure:
      shape.fill(phaseColor.opacity(0.18))
    case .postProcessing:
      shape.fill(phaseColor.opacity(0.06))
    default:
      EmptyView()
    }
  }

  private var strokeWidth: CGFloat {
    switch manager.snapshot.phase {
    case .failure:
      return 2
    default:
      return 1
    }
  }

  @ViewBuilder
  private var animatedGlyph: some View {
    switch manager.snapshot.phase {
    case .failure:
      if shouldUseLegacyRendering || reduceMotion {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(phaseColor)
          .accessibilityLabel("Error indicator")
          .accessibilityAddTraits(.isImage)
      } else {
        TimelineView(.animation) { context in
          let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
          let scale = 0.9 + (progress < 0.5 ? progress : 1 - progress) * 0.35
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 32, weight: .bold))
            .foregroundStyle(phaseColor.gradient)
            .scaleEffect(scale)
            .shadow(color: phaseColor.opacity(0.45), radius: 10, x: 0, y: 6)
            .accessibilityLabel("Error indicator")
            .accessibilityAddTraits(.isImage)
        }
      }
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(phaseColor)
        .shadow(color: phaseColor.opacity(0.3), radius: 6, x: 0, y: 4)
        .accessibilityLabel("Success indicator")
        .accessibilityAddTraits(.isImage)
    default:
      if shouldUseLegacyRendering || reduceMotion {
        Circle()
          .fill(phaseColor)
          .frame(width: 18, height: 18)
          .accessibilityLabel("\(manager.snapshot.headline) status indicator")
          .accessibilityAddTraits(.isImage)
      } else {
        TimelineView(.animation) { context in
          let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
          let scale = 0.9 + (progress < 0.5 ? progress : 1 - progress) * 0.4
          Circle()
            .fill(phaseColor.gradient)
            .frame(width: 18, height: 18)
            .scaleEffect(scale)
            .shadow(color: phaseColor.opacity(0.4), radius: 6, x: 0, y: 4)
            .accessibilityLabel("\(manager.snapshot.headline) status indicator")
            .accessibilityAddTraits(.isImage)
        }
      }
    }
  }

  private var shouldUseLegacyRendering: Bool {
    HUDPlatformWorkarounds.isLegacyRenderingEnabled
  }

  private var hudMaxWidth: CGFloat {
    dynamicTypeSize.isAccessibilitySize || manager.isExpanded ? 500 : 320
  }

  private var opaqueBackgroundColor: Color {
    colorScheme == .dark ? .black : .white
  }

  private var legacyBackgroundColor: Color {
    colorScheme == .dark ? Color.black.opacity(0.82) : Color.white.opacity(0.94)
  }

  private var elapsedText: String {
    let duration = max(manager.snapshot.elapsed, 0)
    let totalHundredths = max(0, Int((duration * 100).rounded()))
    let minutes = totalHundredths / 6000
    let seconds = (totalHundredths / 100) % 60
    let hundredths = totalHundredths % 100
    if minutes > 0 {
      return String(format: "%02d:%02d.%02d", minutes, seconds, hundredths)
    } else {
      return String(format: "%02d.%02ds", seconds, hundredths)
    }
  }
}
// swiftlint:enable type_body_length file_length
