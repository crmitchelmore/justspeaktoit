#if os(iOS)
import Foundation
import SpeakCore

/// Where a running capture records that it is mid-write, so a later launch can
/// tell an interrupted recording from a finished one (issue #992).
///
/// It lives in the App Group container because a capture can be owned by the
/// containing app, the keyboard extension or an intent running headless, and
/// the process that finds the wreckage is usually not the one that made it.
/// When the container is unavailable the store falls back to this process's
/// own defaults: recovery then covers only captures this app made, which is
/// less than ideal and still better than losing them.
///
/// Every decision about what a claim *means* is in ``CaptureRecoveryScanner``,
/// where `swift test` proves it. This type only reads and writes.
public final class CaptureSafetyClaimStore: @unchecked Sendable {
    /// This process launch's identity. A claim carrying it was opened by code
    /// that is still running, which is the strongest liveness evidence there
    /// is and the reason a live capture can never be mistaken for wreckage.
    public static let currentOwner = UUID()

    public static let shared = CaptureSafetyClaimStore()

    private static let storageKey = "captureSafetyClaims.v1"

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private let owner: UUID

    public convenience init() {
        self.init(
            defaults: AppGroupAvailability.verifiedDefaults() ?? UserDefaults.standard,
            owner: CaptureSafetyClaimStore.currentOwner
        )
    }

    public init(defaults: UserDefaults?, owner: UUID = CaptureSafetyClaimStore.currentOwner) {
        self.defaults = defaults
        self.owner = owner
    }

    public var isAvailable: Bool { self.defaults != nil }

    // MARK: - Reading

    public func claims() -> [CaptureSafetyClaim] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.loadLocked()
    }

    // MARK: - Writing

    /// Opens a claim for a capture that has just started writing audio.
    public func open(recording: UUID, fileName: String, startedAt: Date, now: Date = Date()) {
        self.mutate { claims in
            claims.removeAll { $0.run == recording }
            claims.append(CaptureSafetyClaim(
                run: recording,
                fileName: fileName,
                startedAt: startedAt,
                owner: self.owner,
                lastHeartbeat: now
            ))
        }
    }

    /// Refreshes the claim so another process can tell this capture is alive.
    public func heartbeat(recording: UUID, now: Date = Date()) {
        self.mutate { claims in
            guard let index = claims.firstIndex(where: { $0.run == recording }) else { return }
            claims[index].lastHeartbeat = now
        }
    }

    /// Records that the transcript for every capture this process opened and
    /// has since stopped actually reached its destination.
    ///
    /// This runs after the History write rather than at stop, and that is the
    /// whole point: a process killed between the last audio buffer and the
    /// saved transcript leaves its claim un-delivered, which is exactly the
    /// case this feature exists for. Claims of *other* processes are never
    /// touched — this process cannot know what became of their transcripts.
    ///
    /// - Parameter excluding: captures still writing, which keep their claim.
    public func markDeliveredForThisProcess(excluding live: Set<UUID> = []) {
        self.mutate { claims in
            for index in claims.indices
            where claims[index].owner == self.owner && !live.contains(claims[index].run) {
                claims[index].deliveredTranscript = true
            }
        }
    }

    /// Drops a claim record. Never touches the audio file — the caller does
    /// that, or more usually does not.
    public func forget(recording: UUID) {
        self.forget(recordings: [recording])
    }

    public func forget(recordings: [UUID]) {
        guard !recordings.isEmpty else { return }
        let doomed = Set(recordings)
        self.mutate { claims in
            claims.removeAll { doomed.contains($0.run) }
        }
    }

    // MARK: - Private

    private func mutate(_ body: (inout [CaptureSafetyClaim]) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var claims = self.loadLocked()
        body(&claims)
        self.saveLocked(claims)
    }

    private func loadLocked() -> [CaptureSafetyClaim] {
        guard let data = self.defaults?.data(forKey: Self.storageKey) else { return [] }
        // A record this process cannot decode is a record it must not act on,
        // and dropping it would forget audio. Report none rather than some.
        return (try? JSONDecoder().decode([CaptureSafetyClaim].self, from: data)) ?? []
    }

    private func saveLocked(_ claims: [CaptureSafetyClaim]) {
        guard let data = try? JSONEncoder().encode(claims) else { return }
        self.defaults?.set(data, forKey: Self.storageKey)
    }
}
#endif
