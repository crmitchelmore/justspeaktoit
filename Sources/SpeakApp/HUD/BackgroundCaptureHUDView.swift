import SpeakCore
import SwiftUI

/// Subtle, non-intrusive floating pill for background / system-audio captures.
///
/// Tucked into the top-right corner of the screen in a non-activating panel so
/// it never steals focus or obscures the main workspace. Clicking the pill
/// toggles a compact details popover with a Stop button.
struct BackgroundCaptureHUDView: View {
  @ObservedObject var manager: HUDManager
  var onLayoutChange: (() -> Void)?

  @State private var isPopoverOpen = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var phase: HUDPhase { manager.snapshot.phase }
  private var source: AudioCaptureSource { manager.presentationMode.backgroundSource ?? .system }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      pillButton
      if isPopoverOpen {
        expandedPopover
          .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
      }
    }
    .padding(6)
    .fixedSize()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("backgroundCaptureHUD")
    .onChange(of: isPopoverOpen) { _, _ in
      onLayoutChange?()
    }
    .onChange(of: phase) { _, newPhase in
      if !newPhase.isVisible {
        isPopoverOpen = false
      }
      onLayoutChange?()
    }
  }

  private var pillButton: some View {
    Button {
      withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.85)) {
        isPopoverOpen.toggle()
      }
    } label: {
      HStack(spacing: 7) {
        statusIndicator
        Text(pillLabel)
          .font(.caption.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
        if phase == .recording {
          HUDElapsedClock(start: manager.sessionStart, interval: 1) { elapsed in
            Text(Self.elapsedLabel(for: elapsed))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 6)
      .background(pillBackground)
      .overlay(
        Capsule()
          .stroke(borderColor, lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.14), radius: 8, x: 0, y: 3)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(pillLabel) indicator")
    .accessibilityValue(statusDetail)
    .accessibilityHint(isPopoverOpen ? "Hide recording controls" : "Show recording controls and Stop button")
    .accessibilityIdentifier("backgroundCaptureHUDToggle")
  }

  private var expandedPopover: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: source == .both ? "waveform.and.mic" : "speaker.wave.2.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(source.backgroundHUDLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
          Text(statusDetail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button {
          isPopoverOpen = false
          manager.requestStop()
        } label: {
          Label("Stop", systemImage: "stop.fill")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.small)
        .disabled(phase != .recording)
        .accessibilityLabel("Stop \(source.backgroundHUDLabel)")
        .accessibilityIdentifier("backgroundCaptureHUDStopButton")
      }
    }
    .padding(12)
    .frame(width: 216, alignment: .leading)
    .background(popoverBackground)
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("backgroundCaptureHUDPopover")
  }

  @ViewBuilder
  private var statusIndicator: some View {
    switch phase {
    case .recording:
      pulsingDot
    case .transcribing, .postProcessing, .delivering:
      ProgressView()
        .controlSize(.mini)
        .scaleEffect(0.75)
        .frame(width: 10, height: 10)
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .font(.caption2)
        .foregroundStyle(.green)
    case .failure:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.caption2)
        .foregroundStyle(.orange)
    default:
      Circle()
        .fill(Color.secondary)
        .frame(width: 8, height: 8)
    }
  }

  @ViewBuilder
  private var pulsingDot: some View {
    if reduceMotion {
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)
    } else {
      TimelineView(.animation) { context in
        let elapsed = context.date.timeIntervalSinceReferenceDate
        let pulse = 0.5 + 0.5 * sin(elapsed * .pi * 1.4)
        Circle()
          .fill(Color.red)
          .frame(width: 8, height: 8)
          .scaleEffect(0.88 + 0.16 * pulse)
          .shadow(color: Color.red.opacity(0.25 + 0.45 * pulse), radius: 2 + 3 * pulse)
      }
      .frame(width: 10, height: 10)
    }
  }

  private var pillLabel: String {
    switch phase {
    case .recording:
      return source.backgroundHUDLabel
    case .transcribing, .postProcessing, .delivering:
      return "Finalising…"
    case .success:
      return "Saved"
    case .failure:
      return "Capture failed"
    default:
      return source.backgroundHUDLabel
    }
  }

  private var statusDetail: String {
    switch phase {
    case .recording:
      return source.backgroundHUDStatus
    case .transcribing, .postProcessing, .delivering:
      return manager.snapshot.subheadline ?? "Finalising transcript"
    case .success(let message), .failure(let message):
      return message
    default:
      return source.backgroundHUDStatus
    }
  }

  @ViewBuilder
  private var pillBackground: some View {
    if reduceTransparency {
      Capsule().fill(Color(nsColor: .windowBackgroundColor))
    } else {
      Capsule().fill(.regularMaterial)
    }
  }

  @ViewBuilder
  private var popoverBackground: some View {
    if reduceTransparency {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
    } else {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.regularMaterial)
    }
  }

  private var borderColor: Color {
    switch phase {
    case .recording:
      return Color.red.opacity(0.32)
    case .failure:
      return Color.orange.opacity(0.4)
    default:
      return Color.primary.opacity(0.14)
    }
  }

  /// Compact `M:SS` elapsed clock string.
  static func elapsedLabel(for elapsed: TimeInterval) -> String {
    let totalSeconds = max(0, Int(elapsed.rounded(.down)))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
