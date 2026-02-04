#if os(macOS)
import SwiftUI

// MARK: - Shimmer Effect

/// A modifier that applies an animated shimmer effect to a view.
struct ShimmerModifier: ViewModifier {
  @State private var phase: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .overlay(
        GeometryReader { geometry in
          LinearGradient(
            gradient: Gradient(colors: [
              Color.clear,
              Color.white.opacity(0.5),
              Color.clear
            ]),
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: geometry.size.width * 1.5)
          .offset(x: -geometry.size.width * 1.5 + phase * geometry.size.width * 2)
          .blendMode(.overlay)
        }
      )
      .onAppear {
        withAnimation(
          Animation.linear(duration: 1.5)
            .repeatForever(autoreverses: false)
        ) {
          phase = 1
        }
      }
  }
}

extension View {
  /// Applies a shimmer animation to the view.
  func shimmering() -> some View {
    modifier(ShimmerModifier())
  }
}

// MARK: - Skeleton View Components

/// A skeleton placeholder view that animates with a shimmer effect.
struct SkeletonView: View {
  var height: CGFloat = 20
  var cornerRadius: CGFloat = 4

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(Color.gray.opacity(0.2))
      .frame(height: height)
      .shimmering()
  }
}

/// A skeleton circle (for avatars or icons).
struct SkeletonCircle: View {
  var diameter: CGFloat = 40

  var body: some View {
    Circle()
      .fill(Color.gray.opacity(0.2))
      .frame(width: diameter, height: diameter)
      .shimmering()
  }
}

// MARK: - macOS History Skeleton Views

/// Skeleton placeholder for macOS history item row.
struct HistoryItemSkeleton: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Header
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          SkeletonView(height: 12, cornerRadius: 2)
            .frame(width: 80)
          SkeletonView(height: 10, cornerRadius: 2)
            .frame(width: 60)
        }

        Spacer()

        HStack(spacing: 8) {
          SkeletonView(height: 12, cornerRadius: 2)
            .frame(width: 30)
          SkeletonView(height: 12, cornerRadius: 2)
            .frame(width: 40)
        }
      }

      // Transcription preview
      VStack(alignment: .leading, spacing: 4) {
        SkeletonView(height: 16)
        SkeletonView(height: 16)
          .frame(width: 250)
      }

      // Model badge
      HStack {
        SkeletonView(height: 18, cornerRadius: 9)
          .frame(width: 70)
        Spacer()
      }
    }
    .padding(.vertical, 4)
  }
}

/// Skeleton placeholder for history statistics header.
struct HistoryStatsSkeleton: View {
  var body: some View {
    HStack(spacing: 20) {
      statBadgeSkeleton
      statBadgeSkeleton
      statBadgeSkeleton
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
  }

  private var statBadgeSkeleton: some View {
    VStack(spacing: 4) {
      SkeletonView(height: 24, cornerRadius: 4)
        .frame(width: 60)
      SkeletonView(height: 12, cornerRadius: 3)
        .frame(width: 80)
    }
  }
}

// MARK: - Preview

#Preview("macOS Skeleton Loading") {
  VStack {
    HistoryStatsSkeleton()
      .padding()

    ForEach(0..<3, id: \.self) { _ in
      HistoryItemSkeleton()
        .padding()
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(.ultraThinMaterial)
        )
    }
  }
  .padding()
  .frame(width: 400)
}

#endif
