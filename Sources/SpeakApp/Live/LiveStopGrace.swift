import Foundation

/// Applies the user-configured extra stop-grace period uniformly across all
/// live transcription providers. This sits on top of each provider's
/// hard-coded `LiveModelCapabilities.postStopFinalizeBudget` and lets the
/// user buy themselves a bit of extra trailing-audio finalisation time
/// (originally a Deepgram-only knob, now generalised).
func applyLiveStopGrace(_ period: TimeInterval) async {
  let grace = max(period, 0)
  guard grace > 0 else { return }
  try? await Task.sleep(for: .seconds(grace))
}
