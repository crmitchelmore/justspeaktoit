import SwiftUI

/// The streamed transcript line in the full HUD, with its optional
/// confidence chip. Partial text is italic and secondary until it is final.
struct HUDLiveTranscriptView: View {
    let text: String
    let isFinal: Bool
    let confidence: Double?
    let animates: Bool

    var body: some View {
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
                    .speakLiveTranscriptLines(2)
                    .animation(animates ? .easeInOut(duration: 0.2) : nil, value: isFinal)
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
}
