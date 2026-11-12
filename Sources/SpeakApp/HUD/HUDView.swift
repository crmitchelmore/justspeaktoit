import Foundation
import SpeakCore
import SwiftUI

struct HUDOverlay: View {
  @ObservedObject var manager: HUDManager
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if manager.snapshot.phase.isVisible {
      presentedContent
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .accessibilityIdentifier("hudOverlay")
    }
  }

  /// The entrance transition and the phase spring live here, on the container,
  /// so the compact and full HUD styles animate identically. Attaching them
  /// inside the full-HUD branch alone left the compact HUD snapping in and out.
  @ViewBuilder
  private var presentedContent: some View {
    let styled = Group {
      if settings.showCompactHUD {
        CompactHUDContent(manager: manager)
      } else {
        content
      }
    }
    if shouldUseLegacyRendering || reduceMotion {
      styled
    } else {
      styled
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: manager.snapshot.phase)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: manager.isExpanded)
    }
  }

  @ViewBuilder
  private var content: some View {
    let base = VStack(spacing: 12) {
      HUDPhaseGlyph(style: style, headline: manager.snapshot.headline, animates: animates)
        .accessibilityHidden(false)
      statusText
      if case .recording = manager.snapshot.phase {
        AudioLevelMeterView(
          level: manager.audioLevel,
          animatesLevel: animates,
          width: 100,
          height: 4
        )
          .padding(.top, 2)
          .accessibilityLabel("Audio level meter")
          .accessibilityValue("\(Int(manager.audioLevel * 100)) percent")
          .accessibilityAddTraits(.updatesFrequently)
      }
      if manager.isAwaitingAudio {
        HUDAwaitingAudioIndicator()
      } else if manager.snapshot.phase.isTerminal == false, manager.snapshot.phase != .armed {
        // Only this label redraws on the clock's schedule: it reads the phase's
        // start instant off the manager and ticks itself, so the rest of the HUD
        // is invalidated by phase transitions alone.
        HUDElapsedClock(
          start: manager.sessionStart,
          interval: HUDPlatformWorkarounds.elapsedTimerInterval
        ) { elapsed in
          let label = Self.elapsedLabel(for: elapsed)
          Text(label)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityLabel("Elapsed time: \(label)")
            .accessibilityAddTraits(.updatesFrequently)
        }
      }

      // Live transcript section (recording and voice-edit listening phases with content)
      if manager.snapshot.phase == .recording || manager.snapshot.phase == .editing,
         settings.showLiveTranscriptInHUD,
         let transcriptText = manager.snapshot.liveText, !transcriptText.isEmpty {
        // Show the live transcript inline (no disclosure/expand UI).
        HUDLiveTranscriptView(
          text: transcriptText,
          isFinal: manager.snapshot.liveTextIsFinal,
          confidence: manager.snapshot.liveTextConfidence,
          animates: animates
        )
          .padding(.top, 4)
      }

      // Capture health row: shown during recording and failure phases.
      switch manager.snapshot.phase {
      case .recording, .failure:
        HUDCaptureHealthRow(health: manager.captureHealth)
          .padding(.top, 4)
      default:
        EmptyView()
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .accessibilityElement(children: .contain)
    .accessibilitySortPriority(1)
    let shell = base
      .modifier(HUDShell(style: style, usesLegacyRendering: shouldUseLegacyRendering))
      .frame(maxWidth: hudMaxWidth)
      .padding(.horizontal, 60)
      .accessibilityAddTraits(.isModal)
    if animates {
      // The phase/expansion springs live on `presentedContent` so the compact
      // HUD gets the same animation; only the shadow is specific to this shell.
      shell.shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 12)
    } else {
      shell
    }
  }

  private var statusText: some View {
    VStack(spacing: 4) {
      Text(manager.snapshot.headline)
        .font(.headline)
        .foregroundStyle(style.headlineColor)
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
  }

  private var style: HUDPhaseStyle {
    HUDPhaseStyle(phase: manager.snapshot.phase)
  }

  /// Motion is off on the legacy renderer and under Reduce Motion.
  private var animates: Bool {
    !shouldUseLegacyRendering && !reduceMotion
  }

  private var shouldUseLegacyRendering: Bool {
    HUDPlatformWorkarounds.isLegacyRenderingEnabled
  }

  private var hudMaxWidth: CGFloat {
    dynamicTypeSize.isAccessibilitySize || manager.isExpanded ? 500 : 320
  }

  /// Seconds and hundredths, growing a minutes field once the clock passes a
  /// minute: `07.24s`, `01:07.24`. Because it shows hundredths, the full HUD's
  /// clock refreshes at `HUDPlatformWorkarounds.elapsedTimerInterval`.
  /// Exposed at package scope so a test can pin the formatting.
  static func elapsedLabel(for elapsed: TimeInterval) -> String {
    let duration = max(elapsed, 0)
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
