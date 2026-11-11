import SpeakCore
import SwiftUI

/// Preserves lazy single-column rendering in normal density while opting
/// compact density into the width-aware layout.
struct SpeakDensitySettingsSection<Content: View>: View {
  let density: AppVisualDensity
  let compactMinimumWidth: CGFloat
  let maximumColumns: Int
  @ViewBuilder let content: Content

  init(
    density: AppVisualDensity,
    compactMinimumWidth: CGFloat = 340,
    maximumColumns: Int = 3,
    @ViewBuilder content: () -> Content
  ) {
    self.density = density
    self.compactMinimumWidth = compactMinimumWidth
    self.maximumColumns = maximumColumns
    self.content = content()
  }

  var body: some View {
    if density.isCompact {
      SpeakAdaptiveSettingsLayout(
        density: density,
        compactMinimumWidth: compactMinimumWidth,
        maximumColumns: maximumColumns
      ) {
        content
      }
    } else {
      LazyVStack(spacing: density.sectionSpacing) {
        content
      }
    }
  }
}

/// A single-column settings stack in normal mode and a balanced masonry grid
/// in compact mode. Unlike `LazyVGrid`, shorter cards do not inherit the height
/// of the tallest card in their row, so compact mode does not manufacture a
/// second kind of whitespace while trying to remove the first.
struct SpeakAdaptiveSettingsLayout: Layout {
  let density: AppVisualDensity
  let compactMinimumWidth: CGFloat
  let maximumColumns: Int

  struct LayoutCache {
    var width: CGFloat?
    var measurement: Measurement?
  }

  init(
    density: AppVisualDensity,
    compactMinimumWidth: CGFloat = 340,
    maximumColumns: Int = 3
  ) {
    self.density = density
    self.compactMinimumWidth = compactMinimumWidth
    self.maximumColumns = maximumColumns
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout LayoutCache
  ) -> CGSize {
    let width = resolvedWidth(for: proposal, subviews: subviews)
    let result = measure(width: width, subviews: subviews)
    cache.width = width
    cache.measurement = result
    return CGSize(width: width, height: result.height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout LayoutCache
  ) {
    let result: Measurement
    if cache.width == bounds.width, let cachedMeasurement = cache.measurement {
      result = cachedMeasurement
    } else {
      result = measure(width: bounds.width, subviews: subviews)
      cache.width = bounds.width
      cache.measurement = result
    }

    for (index, subview) in subviews.enumerated() {
      guard result.origins.indices.contains(index) else { continue }
      subview.place(
        at: CGPoint(
          x: bounds.minX + result.origins[index].x,
          y: bounds.minY + result.origins[index].y
        ),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: result.columnWidth, height: nil)
      )
    }
  }

  func makeCache(subviews: Subviews) -> LayoutCache {
    LayoutCache()
  }

  func updateCache(_ cache: inout LayoutCache, subviews: Subviews) {
    cache = LayoutCache()
  }

  private func resolvedWidth(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
    if let proposedWidth = proposal.width, proposedWidth.isFinite {
      return proposedWidth
    }

    let idealWidth = subviews
      .map { $0.sizeThatFits(.unspecified).width }
      .filter(\.isFinite)
      .max() ?? compactMinimumWidth
    return max(compactMinimumWidth, idealWidth)
  }

  private func measure(width: CGFloat, subviews: Subviews) -> Measurement {
    guard !subviews.isEmpty else {
      return Measurement(columnWidth: width, origins: [], height: 0)
    }

    let spacing = density.sectionSpacing
    let columnCount = density.adaptiveColumnCount(
      availableWidth: width,
      minimumColumnWidth: compactMinimumWidth,
      maximumColumns: maximumColumns
    )
    let totalSpacing = spacing * CGFloat(columnCount - 1)
    let columnWidth = max(1, (width - totalSpacing) / CGFloat(columnCount))
    var columnHeights = Array(repeating: CGFloat.zero, count: columnCount)
    var origins: [CGPoint] = []

    for subview in subviews {
      let column = shortestColumn(in: columnHeights)
      let size = subview.sizeThatFits(
        ProposedViewSize(width: columnWidth, height: nil)
      )
      origins.append(
        CGPoint(
          x: CGFloat(column) * (columnWidth + spacing),
          y: columnHeights[column]
        )
      )
      columnHeights[column] += size.height + spacing
    }

    let height = max(0, (columnHeights.max() ?? spacing) - spacing)
    return Measurement(columnWidth: columnWidth, origins: origins, height: height)
  }

  private func shortestColumn(in heights: [CGFloat]) -> Int {
    heights.enumerated().min { lhs, rhs in
      if lhs.element == rhs.element {
        return lhs.offset < rhs.offset
      }
      return lhs.element < rhs.element
    }?.offset ?? 0
  }

  struct Measurement {
    let columnWidth: CGFloat
    let origins: [CGPoint]
    let height: CGFloat
  }
}
