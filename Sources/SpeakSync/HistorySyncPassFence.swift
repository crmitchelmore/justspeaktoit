import Foundation

/// Decides whether a History reconciliation pass may still act on what it
/// received.
///
/// A host whose sync can stop partway through a pass — a sign-out, another
/// sign-in, sync turned off, shutdown — gives the coordinator a fence. The
/// pass then loads and saves its cursor, applies remote changes and records
/// acknowledgements only inside `admit`, and passes through it before every
/// request, so a response that arrives after the pass stopped being current
/// is never applied, and nothing more is sent. Without a fence a pass runs to
/// completion, as the native engine always has.
public protocol HistorySyncPassFence: AnyObject {
    /// Runs `work` while the pass is still current, or throws why it is not.
    /// The work runs on the caller's isolation.
    func admit<Value>(
        isolation: isolated (any Actor)?,
        _ work: () async throws -> Value
    ) async throws -> Value
}

extension HistorySyncCoordinator {
    /// Runs one step of the pass through the host's fence, when it has one.
    func admitted<Value>(
        isolation: isolated (any Actor)?,
        _ work: () async throws -> Value
    ) async throws -> Value {
        guard let fence else { return try await work() }
        return try await fence.admit(isolation: isolation, work)
    }
}
