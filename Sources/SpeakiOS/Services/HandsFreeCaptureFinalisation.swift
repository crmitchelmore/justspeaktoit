#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Gives a captured foreground utterance a bounded opportunity to finish after
/// scene inactivity. Expiry preserves the owner's partial result; it never uses
/// the explicit user-Cancel path that clears shared content.
@MainActor
final class HandsFreeCaptureFinalisation {
    enum Failure: LocalizedError {
        case expired

        var errorDescription: String? {
            "Transcription finalisation ran out of time. Available captured text was saved."
        }
    }

    private let timeout: Duration
    private let makeAssertion: @MainActor () -> BackgroundTaskAssertion
    private var assertion: BackgroundTaskAssertion?
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var operationTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var cancelCapture: (() -> Void)?
    private var finished = false

    init(
        timeout: Duration = .seconds(10),
        makeAssertion: @escaping @MainActor () -> BackgroundTaskAssertion = {
            BackgroundTaskAssertion(name: "Finish hands-free utterance")
        }
    ) {
        self.timeout = timeout
        self.makeAssertion = makeAssertion
    }

    func run(
        operation: @escaping @MainActor () async throws -> TranscriptionResult,
        cancelCapture: @escaping () -> Void
    ) async throws -> TranscriptionResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.cancelCapture = cancelCapture
                let assertion = makeAssertion()
                self.assertion = assertion
                assertion.onExpiration = { [weak self] in self?.expire() }
                guard !finished else { return }
                if !assertion.isValid, UIApplication.shared.applicationState != .active {
                    expire()
                    return
                }
                operationTask = Task { [weak self] in
                    do {
                        try Task.checkCancellation()
                        let result = try await operation()
                        self?.complete(.success(result))
                    } catch {
                        self?.complete(.failure(error), cancel: true)
                    }
                }
                deadlineTask = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.expire()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(.failure(CancellationError()), cancel: true) }
        }
    }

    private func expire() {
        complete(.failure(Failure.expired), cancel: true)
    }

    private func complete(_ result: Result<TranscriptionResult, Error>, cancel: Bool = false) {
        guard !finished else { return }
        finished = true
        if cancel {
            // Detach callbacks and release the owned capture before delivering
            // timeout. A provider that ignores cancellation cannot publish late.
            cancelCapture?()
            operationTask?.cancel()
        }
        cancelCapture = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        operationTask = nil
        assertion?.end()
        assertion = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
#endif
