import SpeakCore
import SwiftUI

/// The dashboard's record button, live preview and headline statistics: a
/// single inline strip in compact density, a large banner otherwise.
struct DashboardHeroHeader: View {
  @EnvironmentObject private var environment: AppEnvironment
  @EnvironmentObject private var history: HistoryManager
  @EnvironmentObject private var recording: RecordingControlModel
  @Environment(\.appVisualDensity) private var density
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @ViewBuilder
  var body: some View {
    if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
      compactHeroHeader
    } else {
      normalHeroHeader
    }
  }

  private var compactHeroHeader: some View {
    let stats = history.statistics
    return PageHeroStrip("Dashboard", systemImage: "sparkles.rectangle.stack", palette: .dashboard) {
      Spacer(minLength: 4)

      CompactHeroMetric(
        title: "Sessions",
        value: "\(stats.totalSessions)",
        systemImage: "record.circle"
      )
      CompactHeroMetric(
        title: "Recording time",
        value: DashboardFormat.duration(stats.cumulativeRecordingDuration),
        systemImage: "timer"
      )
      CompactHeroMetric(
        title: "Spend",
        value: DashboardFormat.currency(stats.totalSpend),
        systemImage: "creditcard"
      )

      Button(action: recording.toggle) {
        compactRecordButtonLabel
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .tint(recording.isRecording ? .red : .accentColor)
      .disabled(isBusy)
      .keyboardShortcut(.space, modifiers: [.command])
      .accessibilityLabel(recordButtonAccessibility.label)
      .accessibilityValue(recordButtonAccessibility.value)
      .accessibilityHint(recordButtonAccessibility.hint)
      .accessibilityAddTraits(recordButtonAccessibility.traits)
    } below: {
      if let preview = livePreviewText, !preview.isEmpty {
        Label(preview, systemImage: "waveform")
          .font(.caption.monospaced())
          .speakLiveTranscriptLines(1)
          .foregroundStyle(SpeakTextStyle.onTintSecondary)
      }
    }
  }

  private var normalHeroHeader: some View {
    let stats = history.statistics
    return PageHeroHeader(
      "Speak Dashboard",
      subtitle: "Ready to capture ideas instantly. "
        + "Check permissions, monitor usage, and dive into your latest sessions.",
      palette: .dashboard
    ) {
      Button(action: recording.toggle) {
        recordButtonLabel
          .padding(.horizontal, 32)
          .padding(.vertical, 18)
          .background(
            Capsule()
              .fill(recordButtonBackground)
          )
          .overlay(
            Capsule()
              .stroke(SpeakTextStyle.onTintStroke, lineWidth: 1)
          )
          .foregroundStyle(SpeakTextStyle.onTint)
      }
      .buttonStyle(.plain)
      .contentShape(Capsule())
      .keyboardShortcut(.space, modifiers: [.command])
      .disabled(isBusy)
      .speakTooltip(
        "Start a new recording instantly or stop the current one—Speak keeps you informed every step of the way."
      )
      .accessibilityLabel(recordButtonAccessibility.label)
      .accessibilityValue(recordButtonAccessibility.value)
      .accessibilityHint(recordButtonAccessibility.hint)
      .accessibilityAddTraits(recordButtonAccessibility.traits)
      .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 12)
      .animation(.easeInOut(duration: 0.2), value: recording.state)
    } content: {
      if let preview = livePreviewText, !preview.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Live preview")
            .font(.caption.bold())
            .foregroundStyle(SpeakTextStyle.onTintTertiary)
          Text(preview)
            .font(.body.monospaced())
            .speakLiveTranscriptLines(3)
            .multilineTextAlignment(.leading)
        }
        .padding(16)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(SpeakTextStyle.onTintFill)
        )
      }

      HStack(spacing: 16) {
        HeroStatChip(title: "Sessions", value: "\(stats.totalSessions)", systemImage: "record.circle")
        HeroStatChip(
          title: "Recording Time",
          value: DashboardFormat.duration(stats.cumulativeRecordingDuration),
          systemImage: "timer"
        )
        HeroStatChip(
          title: "Spend",
          value: DashboardFormat.currency(stats.totalSpend),
          systemImage: "creditcard"
        )
      }
    }
  }

  @ViewBuilder
  private var compactRecordButtonLabel: some View {
    switch recording.state {
    case .processing, .delivering:
      ProgressView()
        .controlSize(.mini)
    default:
      Image(systemName: buttonIcon)
    }
  }

  private var livePreviewText: String? {
    guard recording.isRecording else { return nil }
    return environment.main.livePreview
  }

  private var buttonTitle: String {
    switch recording.state {
    case .idle, .completed, .failed:
      return "Start Recording"
    case .recording:
      return "Recording…"
    case .processing:
      return "Transcribing…"
    case .delivering:
      return "Delivering…"
    }
  }

  private var buttonIcon: String {
    switch recording.state {
    case .idle, .completed, .failed:
      return "mic.fill"
    case .recording:
      return "record.circle.fill"
    case .processing:
      return "hourglass"
    case .delivering:
      return "arrowshape.turn.up.right"
    }
  }

  private var recordButtonAccessibility: RecordingControlAccessibility {
    recording.accessibility
  }

  @ViewBuilder
  private var recordButtonLabel: some View {
    switch recording.state {
    case .processing, .delivering:
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        Text(buttonTitle)
          .font(.headline)
      }
    case .recording:
      HStack(spacing: 12) {
        Image(systemName: buttonIcon)
          .font(.headline)
        Text(buttonTitle)
          .font(.headline)
      }
    default:
      HStack(spacing: 12) {
        Image(systemName: buttonIcon)
          .font(.headline)
        Text(buttonTitle)
          .font(.headline)
      }
    }
  }

  private var recordButtonBackground: some ShapeStyle {
    let colors: [Color]
    switch recording.state {
    case .recording:
      colors = [.red, Color.red.opacity(0.75)]
    case .processing, .delivering:
      colors = [Color.gray.opacity(0.8), Color.gray.opacity(0.6)]
    default:
      colors = [Color.accentColor, Color.accentColor.opacity(0.85)]
    }
    // A button fill inside the hero, whose label already uses SpeakTextStyle.onTint.
    // swiftlint:disable:next hand_rolled_gradient_surface
    return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private var isBusy: Bool {
    recording.isBusy
  }
}
