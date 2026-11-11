import SpeakWatchCore
import SwiftUI

/// Root watch UI: one big record button plus the recent-capture list with
/// per-capture sync status.
struct WatchContentView: View {
    @EnvironmentObject private var captureStore: WatchCaptureStore
    @EnvironmentObject private var recorder: WatchAudioRecorder

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    recordButton
                    if let error = recorder.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("watchRecordingError")
                    }
                    if let issue = captureStore.storageIssue {
                        storageNotice(issue)
                    }
                    capturesList
                }
            }
            .navigationTitle("Just Speak")
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                await WatchRecordingCoordinator.shared.toggleRecording()
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.largeTitle.bold())
                    .accessibilityHidden(true)
                if let startedAt = recorder.startedAt {
                    ElapsedTimeText(since: startedAt)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("Record")
                        .font(.body)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.isRecording ? .red : .accentColor)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
        .accessibilityIdentifier("watchRecordButton")
        .primaryActionGestureShortcut()
    }

    /// A queue that could not be read or saved is said so, with the action that can resolve it.
    @ViewBuilder
    private func storageNotice(_ issue: WatchCaptureQueueIssue) -> some View {
        VStack(spacing: 6) {
            Text(issue.message)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("watchQueueStorageIssue")
            if issue.blocksSaving {
                Button("Try again") { captureStore.reloadQueue() }
                    .accessibilityLabel("Read saved recordings again")
                    .accessibilityIdentifier("watchQueueStorageRetry")
            } else if case .setAside = issue {
                Button("OK") { captureStore.dismissStorageNotice() }
                    .accessibilityLabel("Dismiss saved recordings notice")
                    .accessibilityIdentifier("watchQueueStorageDismiss")
            }
        }
    }

    @ViewBuilder
    private var capturesList: some View {
        if !captureStore.captures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Captures")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(captureStore.captures) { capture in
                    WatchCaptureRow(capture: capture)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    /// Makes the record button respond to the Double Tap hand gesture on
    /// watchOS 11+ while keeping the watchOS 10 deployment target.
    @ViewBuilder
    func primaryActionGestureShortcut() -> some View {
        if #available(watchOS 11.0, *) {
            self.handGestureShortcut(.primaryAction)
        } else {
            self
        }
    }
}

/// Ticks once per second while visible; avoids storing a timer per row.
struct ElapsedTimeText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}

struct WatchCaptureRow: View {
    let capture: WatchCapture

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.createdAt, format: .dateTime.hour().minute())
                    .font(.footnote)
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(durationLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("Capture at \(capture.createdAt.formatted(date: .omitted, time: .shortened)), \(durationLabel)")
        )
        .accessibilityValue(statusLabel)
        .accessibilityIdentifier("watchCaptureRow-\(capture.id)")
    }

    private var durationLabel: String {
        let seconds = max(0, Int(capture.duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var statusSymbol: String {
        switch capture.status {
        case .recorded: return "waveform"
        case .transferring: return "arrow.up.circle"
        case .delivered: return "iphone"
        case .transcribed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch capture.status {
        case .recorded, .transferring: return .secondary
        case .delivered: return .blue
        case .transcribed: return .green
        case .failed: return .orange
        }
    }

    private var statusLabel: String {
        switch capture.status {
        case .recorded: return "Waiting to send"
        case .transferring: return "Sending to iPhone…"
        case .delivered: return "On iPhone, transcribing…"
        case .transcribed: return "In history"
        case .failed: return capture.message ?? "Failed"
        }
    }
}
