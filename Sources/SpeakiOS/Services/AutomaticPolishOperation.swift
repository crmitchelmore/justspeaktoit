#if os(iOS)
import Foundation

/// Raw output is written once at Stop. Polishing never receives this capability:
/// UIKit cannot condition a later write atomically on cross-process ownership.
@MainActor
protocol PolishPasteboard: AnyObject {
    func write(_ text: String)
}

@MainActor
final class SystemPolishPasteboard: PolishPasteboard {
    private let clipboard: TranscriptClipboard

    convenience init() {
        self.init(clipboard: .shared)
    }

    init(clipboard: TranscriptClipboard) {
        self.clipboard = clipboard
    }

    func write(_ text: String) {
        self.clipboard.copy(text)
    }
}

@MainActor
final class PolishClipboard {
    private let pasteboard: any PolishPasteboard

    convenience init() {
        self.init(pasteboard: SystemPolishPasteboard())
    }

    init(pasteboard: any PolishPasteboard) {
        self.pasteboard = pasteboard
    }

    func copyRaw(_ text: String) {
        guard !text.isEmpty else { return }
        pasteboard.write(text)
    }
}

/// Owns one provider task and its terminal cleanup, including providers that
/// ignore cancellation and expiration before the task has been installed.
@MainActor
final class AutomaticPolishOperation {
    private let isCurrent: () -> Bool
    private let success: (String, Bool) -> Void
    private let failure: (Error) -> Void
    private let completion: () -> Void
    private var task: Task<Void, Never>?
    private var finished = false

    init(
        isCurrent: @escaping () -> Bool,
        success: @escaping (String, Bool) -> Void,
        failure: @escaping (Error) -> Void,
        completion: @escaping () -> Void
    ) {
        self.isCurrent = isCurrent
        self.success = success
        self.failure = failure
        self.completion = completion
    }

    func start(
        under assertion: BackgroundTaskAssertion,
        isActive: Bool,
        process: @escaping @MainActor () async throws -> String
    ) {
        assertion.onExpiration = { [weak self] in self?.cancel() }
        if Task.isCancelled || (!assertion.isValid && !isActive) { cancel() }
        start(process: process)
    }

    func start(process: @escaping @MainActor () async throws -> String) {
        guard !finished, task == nil else { return }
        task = Task {
            defer { self.finish() }
            do {
                try Task.checkCancellation()
                let polished = try await process()
                try Task.checkCancellation()
                guard !self.finished else { return }
                guard !polished.isEmpty else { throw PostProcessingError.emptyResult }
                let current = self.isCurrent()
                self.success(polished, current)
            } catch {
                guard !self.finished else { return }
                self.failure(error)
            }
        }
    }

    func cancel() {
        task?.cancel()
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        task = nil
        completion()
    }
}
#endif
