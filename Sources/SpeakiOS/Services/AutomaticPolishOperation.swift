#if os(iOS)
import Foundation
import UIKit

/// The token is written in the same pasteboard item as the text. A matching
/// string alone cannot distinguish our write from a later copy of identical text.
@MainActor
protocol PolishPasteboard: AnyObject {
    var changeCount: Int { get }
    var ownershipToken: String? { get }
    var string: String? { get }
    func write(_ text: String, token: String)
}

@MainActor
final class SystemPolishPasteboard: PolishPasteboard {
    private static let tokenType = "com.justspeaktoit.clipboard-operation"
    var changeCount: Int { UIPasteboard.general.changeCount }
    var ownershipToken: String? { UIPasteboard.general.value(forPasteboardType: Self.tokenType) as? String }
    var string: String? { UIPasteboard.general.string }

    func write(_ text: String, token: String) {
        UIPasteboard.general.setItems([["public.utf8-plain-text": text, Self.tokenType: token]])
    }
}

@MainActor
final class PolishClipboard {
    struct Receipt {
        let token: String
        let changeCount: Int
        let writtenAt: TimeInterval
    }

    private let pasteboard: any PolishPasteboard
    private let now: () -> TimeInterval
    private let isActive: @MainActor () -> Bool

    convenience init() {
        self.init(pasteboard: SystemPolishPasteboard())
    }

    init(
        pasteboard: any PolishPasteboard,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }
    ) {
        self.pasteboard = pasteboard
        self.now = now
        self.isActive = isActive
    }

    /// No suspension or retry: never adopt a later copy as this write's receipt.
    /// UIKit may defer changeCount; if it does, we deliberately forgo replacement.
    func copyRaw(_ text: String) -> Receipt? {
        guard !text.isEmpty else { return nil }
        let token = UUID().uuidString
        let before = pasteboard.changeCount
        let writtenAt = now()
        let wasActive = isActive()
        pasteboard.write(text, token: token)
        guard wasActive, isActive(), pasteboard.changeCount == before + 1,
              pasteboard.ownershipToken == token, pasteboard.string == text else { return nil }
        return Receipt(token: token, changeCount: before + 1, writtenAt: writtenAt)
    }

    /// Foreground only: background changeCount can be stale until reactivation.
    /// UIKit offers no atomic cross-process compare-and-write; this synchronous,
    /// conservative check is not a claim of background pasteboard reliability.
    @discardableResult
    func replace(_ text: String, receipt: Receipt) -> Bool {
        guard isActive(), now() - receipt.writtenAt < 20,
              pasteboard.changeCount == receipt.changeCount,
              pasteboard.ownershipToken == receipt.token else { return false }
        pasteboard.write(text, token: receipt.token)
        return true
    }
}

/// Owns one provider task and its terminal cleanup, including providers that
/// ignore cancellation and expiration before the task has been installed.
@MainActor
final class AutomaticPolishOperation {
    private let clipboard: PolishClipboard
    private let receipt: PolishClipboard.Receipt?
    private let isCurrent: () -> Bool
    private let success: (String, Bool) -> Void
    private let failure: (Error) -> Void
    private let completion: () -> Void
    private var task: Task<Void, Never>?
    private var finished = false

    init(
        clipboard: PolishClipboard,
        receipt: PolishClipboard.Receipt?,
        isCurrent: @escaping () -> Bool,
        success: @escaping (String, Bool) -> Void,
        failure: @escaping (Error) -> Void,
        completion: @escaping () -> Void
    ) {
        self.clipboard = clipboard
        self.receipt = receipt
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
                if current, let receipt = self.receipt {
                    self.clipboard.replace(polished, receipt: receipt)
                }
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
