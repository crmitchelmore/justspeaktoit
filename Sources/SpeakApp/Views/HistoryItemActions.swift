import SpeakCore
import AppKit
import SwiftUI

/// The right-click menu of a History row.
struct HistoryItemContextMenu: View {
  let item: HistoryItem
  let environment: AppEnvironment
  let onReviewIssueReport: () -> Void
  let onDelete: () -> Void

  @ViewBuilder
  var body: some View {
    if let raw = item.rawTranscription {
      Button {
        CopyFeedback.copy(raw)
      } label: {
        Label("Copy Raw Transcription", systemImage: "doc.on.doc")
      }
    }

    if let processed = item.postProcessedTranscription {
      Button {
        CopyFeedback.copy(processed)
      } label: {
        Label("Copy Processed Transcription", systemImage: "doc.on.doc.fill")
      }
    }

    if !item.errors.isEmpty {
      Divider()

      Button {
        onReviewIssueReport()
      } label: {
        Label("Review Issue Report…", systemImage: "ladybug")
      }

      Button {
        onReviewIssueReport()
      } label: {
        Label("Review Before Copying…", systemImage: "doc.on.clipboard")
      }
    }

    Divider()

    if item.audioFileURL != nil {
      Button {
        Task { await environment.main.reprocessHistoryItem(item) }
      } label: {
        Label("Reprocess with Current Model", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(environment.main.isBusy)
      .speakTooltip(HistoryReprocessTooltip.text(settings: environment.settings))
    }

    if let url = item.audioFileURL {
      Button {
        NSWorkspace.shared.open(url)
      } label: {
        Label("Play Audio", systemImage: "play.circle")
      }

      Button {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      } label: {
        Label("Show in Finder", systemImage: "folder")
      }
    }

    Divider()

    Button(role: .destructive) {
      onDelete()
    } label: {
      Label("Delete", systemImage: "trash")
    }
  }
}

/// Show in Finder and Reprocess, below an expanded History row.
struct HistoryItemFooterActions: View {
  @EnvironmentObject private var environment: AppEnvironment
  let item: HistoryItem

  var body: some View {
    HStack(spacing: 12) {
      if let url = item.audioFileURL {
        Button {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
          Label("Show in Finder", systemImage: "folder")
        }
        .speakTooltip("Open the folder where this recording lives so you can manage or share the original audio.")

        Button {
          Task { await environment.main.reprocessHistoryItem(item) }
        } label: {
          Label {
            HStack(spacing: 6) {
              Text("Reprocess")
              Image(systemName: "questionmark.circle")
                .imageScale(.small)
            }
          } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(environment.main.isBusy)
        .speakTooltip(HistoryReprocessTooltip.text(settings: environment.settings))
      }
      if environment.main.isBusy {
        ProgressView()
          .controlSize(.small)
      }
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.small)
    .tint(.accentColor)
  }
}

/// Explains which models Reprocess will use with the current settings.
@MainActor
enum HistoryReprocessTooltip {
  static func text(settings: AppSettings) -> String {
    let postProcessing = settings.postProcessingEnabled && settings.speedMode == .instant
      ? """
        Post-processing will also use your current post-processing model: \
        \(ModelCatalog.friendlyName(for: settings.postProcessingModel)).
        """
      : "Post-processing is currently off, so only transcription will be rerun."
    return """
      Reprocess reruns this saved audio with your current settings, not the model originally used. \
      It will use \(modelDescription(settings: settings)). \(postProcessing)
      """
  }

  private static func modelDescription(settings: AppSettings) -> String {
    if settings.transcriptionMode == .localModel {
      let modelName = ModelCatalog.friendlyName(for: settings.localTranscriptionModel)
      if settings.localTranscriptionMode == .streaming {
        return "\(modelName) from Local Batch; Local Streaming candidates are not used for saved-audio reprocessing yet"
      }
      return "\(modelName) from Local Batch"
    }
    return "\(ModelCatalog.friendlyName(for: settings.batchTranscriptionModel)) from Remote Batch"
  }
}
