import SpeakCore
import SwiftUI

/// Settings › Permissions › "System resources in use" (issue #1471): every
/// resource Speak holds right now, why, since when, and a button to let it go.
struct SystemResourcesStatusCard: View {
  @ObservedObject var monitor: SystemResourceMonitor

  var body: some View {
    SettingsCard(
      title: "System resources in use", systemImage: "gauge.with.dots.needle.33percent", tint: Color.orange
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if self.monitor.microphone.isUnattributed {
          SettingsInlineInfo(
            title: "Microphone open, but no feature claims it",
            message: "macOS reports that Speak is recording, yet nothing in Speak says it is. "
              + "Release Everything stops every capture; please report this so it can be fixed.",
            systemImage: "exclamationmark.triangle"
          )
          .accessibilityIdentifier("systemResources.unattributedMicrophone")
        }
        if self.monitor.holds.isEmpty {
          Text("Speak is not holding the microphone, audio, network connections or anything else right now.")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("systemResources.empty")
        } else {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
              ForEach(self.monitor.holds) { hold in
                SystemResourceHoldRow(hold: hold, now: context.date) {
                  Task { await self.monitor.release(hold) }
                }
              }
            }
          }
        }
        HStack {
          Text(Self.microphoneSummary(self.monitor.microphone))
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Release Everything") {
            Task { await self.monitor.releaseEverything() }
          }
          .disabled(!self.monitor.hasReleasableHolds && !self.monitor.microphone.isUnattributed)
          .accessibilityIdentifier("systemResources.releaseEverything")
          .speakTooltip("Stops recordings, playback and listening. The hotkey keeps working.")
        }
      }
    }
  }

  static func microphoneSummary(_ attribution: MicrophoneUseAttribution) -> String {
    switch attribution {
    case .unknown: return "macOS cannot report microphone use on this version."
    case .idle: return "macOS reports the microphone closed."
    case .attributed: return "macOS reports the microphone open, as listed above."
    case .unattributed: return "macOS reports the microphone open."
    case .claimedButClosed: return "macOS reports the microphone closed; the listed hold is paused."
    }
  }
}

private struct SystemResourceHoldRow: View {
  let hold: SystemResourceHold
  let now: Date
  let release: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: self.hold.kind.systemImage)
        .frame(width: 20)
        .foregroundStyle(self.hold.kind == .microphone ? Color.red : Color.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(self.hold.title).font(.body.weight(.medium))
        Text(self.hold.reason).font(.caption).foregroundStyle(.secondary)
        Text(Self.caption(self.hold, now: self.now))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .accessibilityElement(children: .combine)
      Spacer()
      if let title = self.hold.releaseTitle {
        Button(title, action: self.release)
          .buttonStyle(.bordered)
          .disabled(self.hold.isReleasing)
          .accessibilityIdentifier("systemResources.release.\(self.hold.owner)")
      }
    }
    .accessibilityIdentifier("systemResources.hold.\(self.hold.owner)")
  }

  static func caption(_ hold: SystemResourceHold, now: Date) -> String {
    var parts = [hold.kind.displayName, SystemResourceSummary.duration(since: hold.since, now: now)]
    if let detail = hold.detail { parts.append(detail) }
    return parts.joined(separator: " · ")
  }
}
