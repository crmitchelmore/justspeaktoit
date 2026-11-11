import SwiftUI

/// One figure in a page's compact header strip, read as "title: value".
struct CompactHeroMetric: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    Label(self.value, systemImage: self.systemImage)
      .font(.caption2.weight(.semibold))
      .lineLimit(1)
      .accessibilityLabel("\(self.title): \(self.value)")
  }
}

/// One figure in a page's full-size gradient hero header.
struct HeroStatChip: View {
  let title: String
  let value: String
  let systemImage: String

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: self.systemImage)
        .imageScale(.large)
        .foregroundStyle(.white.opacity(0.85))
      VStack(alignment: .leading, spacing: 4) {
        Text(self.title.uppercased())
          .font(.caption.weight(.semibold))
          .foregroundStyle(.white.opacity(0.7))
        Text(self.value)
          .font(.title3.bold())
          .foregroundStyle(.white)
      }
      Spacer()
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.12))
    )
  }
}
