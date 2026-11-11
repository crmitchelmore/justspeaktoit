import SpeakCore
import AppKit
import SwiftUI

/// The errors recorded for a History item.
struct HistoryItemErrorSection: View {
  let item: HistoryItem
  /// Opens the issue-report review sheet; both buttons lead there.
  let onReviewIssueReport: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text("Errors")
          .font(.subheadline.bold())

        Spacer()

        Button {
          onReviewIssueReport()
        } label: {
          Label("Review Issue Report…", systemImage: "ladybug")
        }
        .speakTooltip("Review the exact public draft and JSON before opening GitHub.")

        Button {
          onReviewIssueReport()
        } label: {
          Label("Review Before Copying…", systemImage: "doc.on.clipboard")
        }
        .speakTooltip("Review the exact public draft before choosing to copy it.")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)

      ForEach(item.errors) { error in
        VStack(alignment: .leading, spacing: 2) {
          Text(error.phase.rawValue.capitalized)
            .font(.caption.bold())
          Text(error.message)
          if let debug = error.debugDescription {
            Text(debug)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4)))
      }
    }
  }
}

/// The requests and responses recorded for a History item.
struct HistoryItemNetworkSection: View {
  let item: HistoryItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Network")
        .font(.subheadline.bold())
      ForEach(item.networkExchanges) { exchange in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("\(exchange.method) \(exchange.url.lastPathComponent)")
              .font(.callout.bold())
            Spacer()
            Text("HTTP \(exchange.responseCode)")
              .font(.caption.bold())
              .foregroundStyle(exchange.responseCode >= 400 ? .red : .secondary)
          }

          Divider()

          if !exchange.requestHeaders.isEmpty {
            Text("Request Headers")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Text(HistoryRowFormatting.formattedHeaders(exchange.requestHeaders))
              .font(.caption2.monospaced())
              .textSelection(.enabled)
          }

          if !exchange.requestBodyPreview.isEmpty {
            Text("Request Body")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ScrollView {
              Text(exchange.requestBodyPreview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
          }

          if !exchange.responseHeaders.isEmpty {
            Text("Response Headers")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            Text(HistoryRowFormatting.formattedHeaders(exchange.responseHeaders))
              .font(.caption2.monospaced())
              .textSelection(.enabled)
          }

          if !exchange.responseBodyPreview.isEmpty {
            Text("Response Body")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ScrollView {
              Text(exchange.responseBodyPreview)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
          }
        }
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.thinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.brandAccent.opacity(0.15), lineWidth: 1)
        )
      }
    }
  }
}

/// The post-processing prompt sent for a History item.
struct HistoryItemPromptDisclosure: View {
  let item: HistoryItem

  @ViewBuilder
  var body: some View {
    if let prompt = item.postProcessingPrompt {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 10) {
          Text(prompt.modelIdentifier)
            .font(.caption)
            .foregroundStyle(.secondary)
          if let customPrompt = prompt.customPrompt, !customPrompt.isEmpty {
            promptTextBlock(title: "Custom Cleanup Prompt", text: customPrompt)
          }
          promptTextBlock(title: "System Prompt", text: prompt.systemPrompt)
          promptTextBlock(title: "Transcript Payload", text: prompt.userPrompt)
        }
        .padding(.top, 8)
      } label: {
        Label("Post-processing prompt", systemImage: "text.bubble")
          .font(.subheadline.bold())
      }
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(.thinMaterial)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(Color.brandAccent.opacity(0.15), lineWidth: 1)
      )
    }
  }

  private func promptTextBlock(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.caption.bold())
        .foregroundStyle(.secondary)
      ScrollView {
        Text(text)
          .font(.caption2.monospaced())
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 180)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
  }
}
