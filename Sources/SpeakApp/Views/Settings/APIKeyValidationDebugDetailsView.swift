import SpeakCore
import SwiftUI

struct APIKeyValidationDebugDetailsView: View {
  let debug: APIKeyValidationDebugSnapshot
  @State var isExpanded: Bool = true

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 16) {
        debugSection(title: "Request") {
          debugRow(label: "URL", value: debug.url)
          debugRow(label: "Method", value: debug.method)
          if !debug.requestHeaders.isEmpty {
            headersSection(title: "Headers", headers: debug.requestHeaders)
          }
          if let body = debug.requestBody, !body.isEmpty {
            bodySection(title: "Body", value: body)
          }
        }

        debugSection(title: "Response") {
          if let status = debug.statusCode {
            debugRow(label: "Status", value: String(status))
          }
          if !debug.responseHeaders.isEmpty {
            headersSection(title: "Headers", headers: debug.responseHeaders)
          }
          if let body = debug.responseBody, !body.isEmpty {
            bodySection(title: "Body", value: body)
          }
        }

        if let error = debug.errorDescription, !error.isEmpty {
          debugSection(title: "Error") {
            Text(error)
              .font(.caption.monospaced())
              .foregroundStyle(.red)
          }
        }
      }
      .padding(.top, 6)
    } label: {
      Label("Latest validation details", systemImage: "ladybug")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func debugSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func debugRow(label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label + ":")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .foregroundStyle(.primary)
      Spacer()
    }
  }

  @ViewBuilder
  private func headersSection(title: String, headers: [String: String]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        if headers.values.contains(where: { $0.contains("...") || $0 == "[REDACTED]" }) {
          Image(systemName: "eye.slash.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("Sensitive values are redacted for security")
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        ForEach(headers.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
          HStack(spacing: 4) {
            Text("\(entry.key): \(entry.value)")
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            if entry.value.contains("...") || entry.value == "[REDACTED]" {
              Image(systemName: "lock.fill")
                .font(.system(size: 8))
                .foregroundStyle(.orange)
            }
          }
        }
      }
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  @ViewBuilder
  private func bodySection(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        CopyButton {
          CopyFeedback.writeToPasteboard(value)
        }
        .buttonStyle(.borderless)
        .speakTooltip("Copy to clipboard")
      }
      ScrollView(.vertical) {
        Text(value)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 160)
      .padding(8)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}
