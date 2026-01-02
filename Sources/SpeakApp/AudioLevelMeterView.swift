import SwiftUI

/// A compact audio level meter with gradient coloring (green -> yellow -> red).
struct AudioLevelMeterView: View {
    /// Normalized audio level from 0.0 (silence) to 1.0 (peak/clipping)
    let level: Float

    /// Width of the meter bar
    var width: CGFloat = 120

    /// Height of the meter bar
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Color.primary.opacity(0.1))

                // Level indicator with gradient
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(levelGradient)
                    .frame(width: levelWidth(in: geometry.size.width))
            }
        }
        .frame(width: width, height: height)
        .animation(.linear(duration: 0.033), value: level)
    }

    private func levelWidth(in totalWidth: CGFloat) -> CGFloat {
        max(0, min(totalWidth, CGFloat(level) * totalWidth))
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: 0.5),
                .init(color: .yellow, location: 0.7),
                .init(color: .orange, location: 0.85),
                .init(color: .red, location: 1.0),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// A segmented audio level meter with discrete bars.
struct SegmentedAudioLevelMeterView: View {
    /// Normalized audio level from 0.0 (silence) to 1.0 (peak/clipping)
    let level: Float

    /// Number of segments in the meter
    var segmentCount: Int = 10

    /// Width of the entire meter
    var width: CGFloat = 120

    /// Height of the meter
    var height: CGFloat = 8

    /// Spacing between segments
    var spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<segmentCount, id: \.self) { index in
                segmentView(for: index)
            }
        }
        .frame(width: width, height: height)
        .animation(.linear(duration: 0.033), value: level)
    }

    private func segmentView(for index: Int) -> some View {
        let threshold = Float(index) / Float(segmentCount)
        let isActive = level > threshold

        return RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(segmentColor(for: index, active: isActive))
    }

    private func segmentColor(for index: Int, active: Bool) -> Color {
        guard active else {
            return Color.primary.opacity(0.15)
        }

        let position = Float(index) / Float(segmentCount)
        if position < 0.5 {
            return .green
        } else if position < 0.7 {
            return .yellow
        } else if position < 0.85 {
            return .orange
        } else {
            return .red
        }
    }
}

struct AudioLevelMeterView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            Text("Continuous Meter")
                .font(.caption)
            AudioLevelMeterView(level: 0.0)
            AudioLevelMeterView(level: 0.3)
            AudioLevelMeterView(level: 0.6)
            AudioLevelMeterView(level: 0.8)
            AudioLevelMeterView(level: 1.0)

            Divider()

            Text("Segmented Meter")
                .font(.caption)
            SegmentedAudioLevelMeterView(level: 0.0)
            SegmentedAudioLevelMeterView(level: 0.3)
            SegmentedAudioLevelMeterView(level: 0.6)
            SegmentedAudioLevelMeterView(level: 0.8)
            SegmentedAudioLevelMeterView(level: 1.0)
        }
        .padding()
        .frame(width: 200, height: 400)
    }
}
