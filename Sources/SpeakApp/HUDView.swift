import SwiftUI

struct HUDOverlay: View {
  @ObservedObject var manager: HUDManager
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    if manager.snapshot.phase.isVisible {
      content
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }
  }

  private var content: some View {
    let base = VStack(spacing: 12) {
      animatedGlyph
      VStack(spacing: 4) {
        Text(manager.snapshot.headline)
          .font(.headline)
          .foregroundStyle(headlineColor)
        if let sub = manager.snapshot.subheadline {
          Text(sub)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        if manager.snapshot.showRetryHint {
          Text("Press ⌘R to retry")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
      }
      if case .recording = manager.snapshot.phase {
        AudioLevelMeterView(level: manager.audioLevel, width: 100, height: 4)
          .padding(.top, 2)
      }
      if manager.snapshot.phase.isTerminal == false {
        Text(elapsedText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      // Live transcript section (only during recording phase with content)
      if case .recording = manager.snapshot.phase, settings.showLiveTranscriptInHUD {
        transcriptSection
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    return hudShell(base)
      .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 12)
      .animation(.spring(response: 0.25, dampingFraction: 0.85), value: manager.snapshot)
      .animation(.spring(response: 0.25, dampingFraction: 0.85), value: manager.isExpanded)
      .frame(maxWidth: manager.isExpanded ? 500 : 320)
      .padding(.horizontal, 60)
  }

  @ViewBuilder
  private func hudShell<Content: View>(_ view: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    if #available(macOS 26.0, *) {
      view
        .background(phaseTint)
        .glassEffect(.regular.tint(phaseColor.opacity(0.18)).interactive(), in: .rect(cornerRadius: 20))
        .overlay(shape.stroke(phaseColor.opacity(0.35), lineWidth: strokeWidth))
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
      Text(text)
        .font(isFinal ? .callout : .callout.italic())
        .fontWeight(isFinal ? .regular : .light)
        .foregroundStyle(isFinal ? .primary : .secondary)
        .lineLimit(2)
        .truncationMode(.head)
        .animation(.easeInOut(duration: 0.2), value: isFinal)

      if let confidence, confidence > 0 {
        Text("\(Int(confidence * 100))%")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 4)
          .padding(.vertical, 2)
          .background(
            Capsule()
              .fill(.quaternary)
          )
      }
    }
    .frame(maxWidth: 300)
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

  private var phaseColor: Color {
    switch manager.snapshot.phase {
    case .recording:
      return .red
    case .transcribing:
      return .brandLagoon
    case .postProcessing:
      return .brandAccent
    case .delivering:
      return .green
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
      TimelineView(.animation) { context in
        let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        let scale = 0.9 + (progress < 0.5 ? progress : 1 - progress) * 0.35
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 32, weight: .bold))
          .foregroundStyle(phaseColor.gradient)
          .scaleEffect(scale)
          .shadow(color: phaseColor.opacity(0.45), radius: 10, x: 0, y: 6)
      }
    case .success:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(phaseColor)
        .shadow(color: phaseColor.opacity(0.3), radius: 6, x: 0, y: 4)
    default:
      TimelineView(.animation) { context in
        let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
        let scale = 0.9 + (progress < 0.5 ? progress : 1 - progress) * 0.4
        Circle()
          .fill(phaseColor.gradient)
          .frame(width: 18, height: 18)
          .scaleEffect(scale)
          .shadow(color: phaseColor.opacity(0.4), radius: 6, x: 0, y: 4)
      }
    }
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

struct HUDOverlay_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      // Compact preview
      HUDOverlay(manager: previewManager)
        .frame(width: 600, height: 400)
        .previewDisplayName("Compact")

      // Expanded with transcript
      HUDOverlay(manager: expandedPreviewManager)
        .frame(width: 600, height: 500)
        .previewDisplayName("Expanded with Transcript")
    }
  }

  private static var previewManager: HUDManager {
    let manager = HUDManager()
    manager.beginRecording()
    return manager
  }

  private static var expandedPreviewManager: HUDManager {
    let manager = HUDManager()
    manager.beginRecording()
    manager.updateLiveTranscription(
      text: "Hello, this is a test of the live transcription feature. It should scroll and show the text properly. And this is still being spoken...",
      isFinal: false,
      confidence: 0.92
    )
    manager.isExpanded = true
    return manager
  }
}
// @Implement: This is the view that shows a floating indicator at the bottom middle of the screen. This view should float on top of all windows in the system but only show when recording is in progress. This should be a minimal view but must be engaging and informative to the users. It should have a cool animated graphic for each phase.
// - Recording: Show in red and how long recording is for with a cool icon as well as animation
// - Transcribing: If the operation is a batch request, this is the transcribing phase waiting for the raw transcription to return
// - Post Processing: This is the call to an LLM to clean up the transcription and also is be optional based on app settings
// - Error: IF any phase errors show the error message.
