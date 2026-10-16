import Foundation
import SpeakCore

/// A native lease may read only its acknowledged insertion's retained field/range.
public protocol DesktopCorrectionReadback: Sendable {
    var application: String? { get }
    func begin(original: String) throws
    func read() throws -> String
    func cancel()
}

/// Cancellation is synchronous; even a blocked native read cannot admit a late edit.
public final class DesktopCorrectionObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let native: any DesktopCorrectionReadback
    public var application: String? { self.native.application }
    public var isCurrent: Bool { self.lock.withLock { !self.cancelled } }

    public init(native: any DesktopCorrectionReadback) { self.native = native }

    public func cancel() {
        self.lock.withLock { self.cancelled = true }
        self.native.cancel()
    }

    public func sample(
        original: String,
        wait: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) async throws -> String {
        guard !original.isEmpty, original.utf16.count <= AutoCorrectionLearningPolicy.maximumUTF16Units else {
            throw DesktopCorrectionObservationError.unsupported
        }
        return try await withTaskCancellationHandler {
            try self.requireCurrent()
            let native = self.native
            try await Task.detached { try native.begin(original: original) }.value
            try self.requireCurrent()
            try await wait(AutoCorrectionLearningPolicy.observationSeconds(for: original))
            try self.requireCurrent()
            let edited = try await Task.detached { try native.read() }.value
            try self.requireCurrent()
            guard edited.utf16.count <= AutoCorrectionLearningPolicy.maximumUTF16Units else {
                throw DesktopCorrectionObservationError.unsupported
            }
            return edited
        } onCancel: {
            self.cancel()
        }
    }

    private func requireCurrent() throws {
        guard self.isCurrent, !Task.isCancelled else { throw CancellationError() }
    }
}

public enum DesktopCorrectionObservationError: LocalizedError {
    case unsupported
    public var errorDescription: String? {
        "Correction learning skipped: this insertion has no safely retained editable text range."
    }
}
