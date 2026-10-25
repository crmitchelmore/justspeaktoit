#if os(macOS)
import Foundation
import SpeakCore

/// One subscription per accepted named capture. The server owns deadlines and sharing;
/// cancellation removes the History observer even if the capture never finishes.
@MainActor
final class AutomationTranscriptWaiter {
    private let history: HistoryManager
    private let activeCapture: () -> UUID?
    var didSubscribe: (() -> Void)?
    private var preparation: Task<Void, Never>?
    private var preparing: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waits: [UUID: (UUID, CheckedContinuation<AutomationResult, Error>)] = [:]

    init(history: HistoryManager, activeCapture: @escaping () -> UUID?) {
        self.history = history
        self.activeCapture = activeCapture
    }

    func wait(for request: AutomationRequest) async throws -> AutomationResult {
        _ = try request.validated()
        try await self.prepare()
        try Task.checkCancellation()
        guard self.history.loadState.isReady,
              let capture = request.captureID.flatMap(UUID.init(uuidString:)),
              self.activeCapture() == capture,
              self.history.item(id: capture) == nil else {
            throw AutomationError(code: .invalidArgument, message: "Capture is not active or already has a result.")
        }
        if let since = request.sinceID.flatMap(UUID.init(uuidString:)), self.history.item(id: since) == nil {
            throw AutomationError(code: .invalidArgument, message: "History baseline is unknown or deleted.")
        }
        // No suspension between the current-row checks, cursor and observer installation.
        let revision = self.history.automationAppendRevision
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let observer = self.history.observeAutomationCapture { [weak self] event in
                    guard event.captureID == capture else { return }
                    guard let item = event.item, event.revision > revision,
                          item.id == capture else {
                        self?.finish(token, result: .failure(AutomationError(
                            code: .transcriptionFailed, message: "Capture ended without a successful transcript.")))
                        return
                    }
                    let text = AppAutomationHandler.transcript(of: item)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self?.finish(token, result: .failure(AutomationError(
                            code: .transcriptionFailed, message: "Capture contained no transcript.")))
                        return
                    }
                    let entry = AutomationHistoryEntry(
                        id: item.id.uuidString, text: text, createdAt: item.createdAt,
                        model: item.modelUsages.first?.modelIdentifier ?? item.modelsUsed.first,
                        durationSeconds: item.recordingDuration, wordCount: AutomationHistoryEntry.wordCount(of: text)
                    )
                    self?.finish(token, result: .success(AutomationResult(
                        text: text, model: entry.model, durationSeconds: entry.durationSeconds,
                        sessionActive: false, captureID: capture.uuidString, entry: entry
                    )))
                }
                self.waits[token] = (observer, continuation)
                self.didSubscribe?()
                if Task.isCancelled { self.finish(token, result: .failure(CancellationError())) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(token, result: .failure(CancellationError())) }
        }
    }

    /// A single shared readiness operation; cancelled clients remove their continuations immediately.
    /// An uncooperative startup/migration cannot accumulate a task for every timed-out client.
    private func prepare() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.preparing[token] = continuation
                if Task.isCancelled {
                    self.preparing.removeValue(forKey: token)?.resume(throwing: CancellationError())
                    return
                }
                if self.preparation == nil {
                    let history = self.history
                    self.preparation = Task { @MainActor [weak self] in
                        await history.prepareForAutomationObservation()
                        guard let self else { return }
                        let pending = self.preparing
                        self.preparing.removeAll()
                        self.preparation = nil
                        for continuation in pending.values { continuation.resume() }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.preparing.removeValue(forKey: token)?.resume(throwing: CancellationError())
            }
        }
    }

    private func finish(_ token: UUID, result: Result<AutomationResult, Error>) {
        guard let (observer, continuation) = self.waits.removeValue(forKey: token) else { return }
        self.history.removeAutomationCaptureObserver(observer)
        continuation.resume(with: result)
    }
}
#endif
