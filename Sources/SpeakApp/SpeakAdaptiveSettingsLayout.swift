import SpeakCore
import SwiftUI

/// A single-column settings stack in normal mode and a balanced masonry grid
/// in compact mode. Unlike `LazyVGrid`, shorter cards do not inherit the height
/// of the tallest card in their row, so compact mode does not manufacture a
/// second kind of whitespace while trying to remove the first.
struct SpeakAdaptiveSettingsLayout: Layout {
  let density: AppVisualDensity
  let compactMinimumWidth: CGFloat
  let maximumColumns: Int

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
    cache: inout ()
  ) -> CGSize {
    let width = resolvedWidth(for: proposal, subviews: subviews)
    let result = measure(width: width, subviews: subviews)
    return CGSize(width: width, height: result.height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let result = measure(width: bounds.width, subviews: subviews)

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

  private struct Measurement {
    let columnWidth: CGFloat
    let origins: [CGPoint]
    let height: CGFloat
  }
}
