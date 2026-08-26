import Foundation
import SpeakCore
import SwiftUI

/// The compact heads-up display: a small card showing a pulsing record dot, a
/// live audio-level meter, the elapsed timer and a single scrolling transcript
/// line. Selected with the "Show compact HUD" setting, it takes over from the
/// full ``HUDOverlay`` content while enabled.
///
/// Layout (top row): the dot sits on the left, the level meter is centred, and
/// the timer sits on the right. The dot pulses on a steady beat to show the app
/// is live (it does not react to volume). The meter is the only element that
/// tracks how loudly you are speaking. Beneath the top row, a single transcript
/// line is anchored to the right so the newest words stay visible while older
/// ones scroll off the left.
struct CompactHUDContent: View {
  @ObservedObject var manager: HUDManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var snapshot: HUDManager.Snapshot { manager.snapshot }
  private var phase: HUDManager.Snapshot.Phase { snapshot.phase }

  var body: some View {
    VStack(spacing: 7) {
      topRow
      transcriptLine
      captureFooter
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .frame(width: 244)
    .background(cardBackground)
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .stroke((washColor ?? Color.gray).opacity(0.35), lineWidth: 1.5)
    )
    .shadow(color: .black.opacity(0.16), radius: 16, x: 0, y: 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("compactHUD")
  }

  // MARK: - Top row (dot · meter · timer)

  private var topRow: some View {
    ZStack {
      if phase == .recording {
        CompactLevelMeter(level: manager.audioLevel, animates: !reduceMotion)
      }
      HStack(spacing: 8) {
        recordDot
        Spacer(minLength: 8)
        timerLabel
      }
    }
    .frame(height: 24)
  }

  @ViewBuilder
  private var recordDot: some View {
    let size: CGFloat = 15
    Group {
      if shouldPulse, !reduceMotion {
        TimelineView(.animation) { context in
          let elapsed = context.date.timeIntervalSinceReferenceDate
          let pulse = 0.5 + 0.5 * sin(elapsed * .pi * 1.6)
          Circle()
            .fill(dotColor)
            .frame(width: size, height: size)
            .scaleEffect(0.9 + 0.12 * pulse)
            .shadow(color: dotColor.opacity(0.25 + 0.4 * pulse), radius: 3 + 5 * pulse)
        }
      } else {
        Circle()
          .fill(dotColor)
          .frame(width: size, height: size)
      }
    }
    .frame(width: 22, height: 22, alignment: .center)
    .accessibilityLabel("\(snapshot.headline) indicator")
    .accessibilityAddTraits(.updatesFrequently)
  }

  @ViewBuilder
  private var timerLabel: some View {
    if phaseHasTimer {
      Text(compactElapsed)
        .font(.system(size: 15, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel("Elapsed time: \(compactElapsed)")
        .accessibilityAddTraits(.updatesFrequently)
    } else {
      // Reserve the trailing slot so the dot stays hard against the left edge.
      Color.clear.frame(width: 1, height: 1)
    }
  }

  // MARK: - Transcript / status line

  @ViewBuilder
  private var transcriptLine: some View {
    if phase == .recording {
      if let text = snapshot.liveText, !text.isEmpty {
        Text(text)
          .font(.system(size: 14))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.head)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .accessibilityLabel("Transcript: \(text)")
      }
    } else if !statusText.isEmpty {
      Text(statusText)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityLabel(statusText)
    }
  }

  private var statusText: String {
    switch phase {
    case .success, .failure:
      return snapshot.subheadline ?? snapshot.headline
    default:
      return snapshot.headline
    }
  }

  // MARK: - Capture footer (device · model)

  @ViewBuilder
  private var captureFooter: some View {
    let health = manager.captureHealth
    if !health.providerLabel.isEmpty || !health.inputDeviceName.isEmpty {
      HStack(spacing: 6) {
        Image(systemName: health.noInputDevicesAvailable ? "mic.slash.fill" : "mic.fill")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(health.noInputDevicesAvailable ? Color.red : .secondary)
        Text(deviceLabel(health))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        if !health.providerLabel.isEmpty {
          Text(verbatim: "·")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
          Text(health.providerLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .layoutPriority(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Input \(deviceLabel(health)), provider \(health.providerLabel)")
    }
  }

  private func deviceLabel(_ health: CaptureHealthSnapshot) -> String {
    health.noInputDevicesAvailable ? "No microphone" : health.inputDeviceName
  }

  // MARK: - Derived state

  /// The dot pulses only while the app is live (armed or recording); processing
  /// and terminal phases show a steady dot.
  private var shouldPulse: Bool {
    phase == .recording || phase == .armed
  }

  /// Mirrors the full HUD: the timer is shown for every non-terminal phase
  /// except `armed`, which has no running clock.
  private var phaseHasTimer: Bool {
    phase.isTerminal == false && phase != .armed
  }

  private var compactElapsed: String {
    Self.elapsedLabel(for: snapshot.elapsed)
  }

  /// Minutes and seconds with a trailing `s`, no fractional seconds:
  /// `40s`, `1:23s`. Whole seconds only, so it counts up a second at a time.
  /// Exposed at package scope for testing.
  static func elapsedLabel(for elapsed: TimeInterval) -> String {
    let totalSeconds = Int(max(elapsed, 0))
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return minutes > 0
      ? String(format: "%d:%02ds", minutes, seconds)
      : "\(seconds)s"
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 20, style: .continuous)
      .fill(.thickMaterial)
      .overlay(washOverlay)
  }

  /// The card stays calm grey while arming, recording and processing; it only
  /// takes on colour for the final outcome - green on delivery, red on failure.
  @ViewBuilder
  private var washOverlay: some View {
    if let washColor {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(washColor.opacity(0.18))
    }
  }

  private var washColor: Color? {
    switch phase {
    case .delivering, .success:
      return .green
    case .failure:
      return .red
    default:
      return nil
    }
  }

  private var dotColor: Color {
    switch phase {
    case .armed:
      return .green
    case .recording, .failure:
      return .red
    case .transcribing:
      return .brandLagoon
    case .postProcessing:
      return .brandAccent
    case .delivering, .success:
      return .green
    case .editing:
      return .brandAccentWarm
    case .hidden:
      return .gray
    }
  }
}

/// A small upright equaliser that rises and falls with the recording level.
/// Each bar has a fixed relative weight so the cluster keeps a natural shape,
/// scaled by the current audio level (0...1). A short floor keeps every bar
/// faintly visible so the meter never disappears entirely mid-recording.
private struct CompactLevelMeter: View {
  let level: Float
  let animates: Bool

  private let weights: [CGFloat] = [0.55, 0.85, 0.62, 1.0, 0.6]
  private let maxHeight: CGFloat = 22

  var body: some View {
    HStack(alignment: .bottom, spacing: 3) {
      ForEach(weights.indices, id: \.self) { index in
        Capsule()
          .fill(meterGradient)
          .frame(width: 3.5, height: barHeight(for: index))
          .animation(animates ? .easeOut(duration: 0.12) : nil, value: level)
      }
    }
    .frame(height: maxHeight, alignment: .bottom)
    .accessibilityHidden(true)
  }

  private func barHeight(for index: Int) -> CGFloat {
    let clamped = CGFloat(min(max(level, 0), 1))
    return max(3, weights[index] * clamped * maxHeight)
  }

  private var meterGradient: LinearGradient {
    LinearGradient(
      gradient: Gradient(colors: [
        Color(red: 0.18, green: 0.75, blue: 0.48),
        Color(red: 0.55, green: 0.80, blue: 0.32),
        Color(red: 0.90, green: 0.71, blue: 0.24)
      ]),
      startPoint: .bottom,
      endPoint: .top
    )
  }
}

struct CompactHUDContent_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      compact(name: "Compact – Recording")
      compact(name: "Compact – Dark")
        .preferredColorScheme(.dark)
    }
  }

  private static func compact(name: String) -> some View {
    let settings = AppSettings()
    settings.showCompactHUD = true
    let manager = HUDManager(appSettings: settings)
    manager.beginRecording()
    manager.updateCaptureHealth(
      CaptureHealthSnapshot(
        microphonePermission: .granted,
        noInputDevicesAvailable: false,
        inputDeviceName: "USB Audio",
        providerLabel: "Deepgram Nova-3 (Streaming)",
        latencyTier: .fast
      )
    )
    manager.updateLiveTranscription(
      text: "so the meter sits in the middle and the newest words stay on the right",
      isFinal: false,
      confidence: 0.94
    )
    manager.updateAudioLevel(0.6)
    return CompactHUDContent(manager: manager)
      .environmentObject(settings)
      .frame(width: 520, height: 320)
      .previewDisplayName(name)
  }
}
