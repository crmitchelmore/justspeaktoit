import SwiftUI

/// Draws a HUD clock from the instant its phase started, on a schedule of its
/// own, so the running time never has to be republished through the manager.
///
/// `start` comes from ``HUDManager/sessionStart``, which changes only on a
/// phase transition; `interval` is the resolution the caller actually displays
/// (hundredths for the full HUD, whole seconds for the compact one). Anchoring
/// the schedule to `start` also lines every tick up with the moment the shown
/// value changes. A `nil` start means the phase has no clock, so the label
/// renders a static zero rather than a live one.
struct HUDElapsedClock<Content: View>: View {
  let start: Date?
  let interval: TimeInterval
  private let content: (TimeInterval) -> Content

  init(
    start: Date?,
    interval: TimeInterval,
    @ViewBuilder content: @escaping (TimeInterval) -> Content
  ) {
    self.start = start
    self.interval = interval
    self.content = content
  }

  var body: some View {
    if let start {
      TimelineView(.periodic(from: start, by: interval)) { context in
        content(max(context.date.timeIntervalSince(start), 0))
      }
    } else {
      content(0)
    }
  }
}

/// Stands in for the elapsed clock while the microphone is still coming up:
/// showing "0s" would read as a clock that has started.
struct HUDAwaitingAudioIndicator: View {
  var body: some View {
    ProgressView()
      .controlSize(.mini)
      .accessibilityLabel("Getting ready")
  }
}
