#if os(iOS)
import SwiftUI

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.brandLagoon)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

struct CheckRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
    }
}

struct PermissionRow: View {
    let icon: String
    let name: String
    let required: Bool

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(Color.brandLagoon)
                .frame(width: 24)
            Text(name)
                .font(.caption)
            Spacer()
            Text(required ? "Required" : "Optional")
                .font(.caption2)
                .foregroundStyle(required ? .red : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(required ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1), in: Capsule())
        }
    }
}
#endif
