import SpeakCore
import SwiftUI

/// The Voice Output page header: title, the synthesis or playback action, and
/// the draft's character count, estimated cost and last duration.
struct VoiceOutputHeader: View {
  @ObservedObject var composer: VoiceOutputComposer
  @EnvironmentObject private var tts: TextToSpeechManager
  @Environment(\.appVisualDensity) private var density

  var body: some View {
    if self.density.isCompact {
      self.compactHeader
    } else {
      self.normalHeader
    }
  }

  private var formattedCost: String? {
    guard let cost = self.composer.estimatedCost, cost > 0 else { return nil }
    return String(format: "$%.4f", NSDecimalNumber(decimal: cost).doubleValue)
  }

  private var formattedLastDuration: String? {
    self.tts.lastResult.map { String(format: "%.1fs", $0.duration) }
  }

  // MARK: - Compact

  private var compactHeader: some View {
    PageHeroStrip("Voice", systemImage: "speaker.wave.3", palette: .voiceOutput) {
      Spacer(minLength: 4)
      CompactHeroMetric(
        title: "Characters", value: "\(self.composer.inputText.count)", systemImage: "textformat.abc"
      )
      if let cost = self.formattedCost {
        CompactHeroMetric(title: "Estimated cost", value: cost, systemImage: "dollarsign.circle")
      }
      if let duration = self.formattedLastDuration {
        CompactHeroMetric(title: "Last duration", value: duration, systemImage: "waveform")
      }
      self.compactAction
    }
  }

  @ViewBuilder
  private var compactAction: some View {
    if self.tts.isSynthesizing {
      Button("Cancel") { self.tts.stop() }
        .buttonStyle(.borderless)
        .accessibilityLabel("Cancel voice synthesis")
    } else if self.tts.isPlaying {
      Button {
        self.tts.stop()
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Stop voice output")
      .accessibilityAddTraits(.isButton)
    }
  }

  // MARK: - Normal

  private var normalHeader: some View {
    PageHeroHeader(
      "Voice Output",
      subtitle: "Convert text to natural speech with multiple providers and advanced controls.",
      palette: .voiceOutput
    ) {
      self.heroAction
    } content: {
      HStack(spacing: 16) {
        HeroStatChip(title: "Characters", value: "\(self.composer.inputText.count)", systemImage: "textformat.abc")
        if let cost = self.formattedCost {
          HeroStatChip(title: "Est. Cost", value: cost, systemImage: "dollarsign.circle")
        }
        if let duration = self.formattedLastDuration {
          HeroStatChip(title: "Last Duration", value: duration, systemImage: "waveform")
        }
      }
    }
  }

  @ViewBuilder
  private var heroAction: some View {
    if self.tts.isSynthesizing {
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        Text("Synthesizing…")
          .font(.headline)
        Button("Cancel") { self.tts.stop() }
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 18)
      .background(Capsule().fill(SpeakTextStyle.onTintFill))
    } else if self.tts.isPlaying {
      Button("Stop") {
        self.tts.stop()
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 18)
      .background(Capsule().fill(SpeakTextStyle.onTintFill))
      .overlay(Capsule().stroke(SpeakTextStyle.onTintStroke, lineWidth: 1))
      .buttonStyle(.plain)
    }
  }
}
