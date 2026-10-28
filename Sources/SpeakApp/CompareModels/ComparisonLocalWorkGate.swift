import Foundation

/// Comparison-only admission. A timed-out waiter does not release native work's permit:
/// the actual operation still owns it until its async call exits.
@MainActor
final class ComparisonLocalWorkGate {
    static let shared = ComparisonLocalWorkGate()

    struct Permit: Equatable {
        fileprivate let modelID: String
        fileprivate let owner: UUID
    }

    private var owners: [String: UUID] = [:]

    func acquire(modelID: String) -> Permit? {
        guard self.owners[modelID] == nil else { return nil }
        let permit = Permit(modelID: modelID, owner: UUID())
        self.owners[modelID] = permit.owner
        return permit
    }

    func release(_ permit: Permit) {
        guard self.owners[permit.modelID] == permit.owner else { return }
        self.owners[permit.modelID] = nil
    }

    func run<Value: Sendable>(
        modelID: String,
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard let permit = self.acquire(modelID: modelID) else { throw ComparisonLocalWorkError.modelBusy }
        defer { self.release(permit) }
        return try await operation()
    }
}

enum ComparisonLocalWorkError: LocalizedError, Equatable {
    case modelBusy

    var errorDescription: String? {
        "A previous comparison for this model is still active. Try again when it finishes."
    }
}
