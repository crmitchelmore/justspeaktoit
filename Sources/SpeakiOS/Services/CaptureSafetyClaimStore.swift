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

    /// One key per claim. A single array under one key made every mutation a
    /// load-modify-save of the *whole* set, and the containing app, the
    /// keyboard extension and a headless intent all mutate it. An in-process
    /// lock cannot order those: two processes could each read the same array
    /// and write back a different modification, and the later write would
    /// silently drop the earlier claim — losing a recoverable recording or its
    /// liveness state. Writing each claim under its own key means a mutation
    /// only ever rewrites the claim it names, so unrelated concurrent updates
    /// from another process survive it.
    private static let claimKeyPrefix = "captureSafetyClaim.v1."
    /// The pre-per-key storage. Read once and split into per-claim keys, so an
    /// install that crashed while holding claims does not lose them.
    private static let legacyStorageKey = "captureSafetyClaims.v1"

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
        self.migrateLegacyLocked()
        return self.loadAllLocked()
    }

    // MARK: - Writing

    /// Opens a claim for a capture that has just started writing audio.
    public func open(recording: UUID, fileName: String, startedAt: Date, now: Date = Date()) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.migrateLegacyLocked()
        self.saveLocked(CaptureSafetyClaim(
            run: recording,
            fileName: fileName,
            startedAt: startedAt,
            owner: self.owner,
            lastHeartbeat: now
        ))
    }

    /// Refreshes the claim so another process can tell this capture is alive.
    public func heartbeat(recording: UUID, now: Date = Date()) {
        self.mutate(recording) { claim in claim.lastHeartbeat = now }
    }

    /// Records that the transcript for one capture reached its destination.
    ///
    /// This runs after the History write rather than at stop, and that is the
    /// whole point: a process killed between the last audio buffer and the
    /// saved transcript leaves its claim un-delivered, which is exactly the
    /// case this feature exists for.
    ///
    /// It is scoped to the one capture whose result was delivered. Marking
    /// every stopped claim this process holds would classify an earlier,
    /// still-pending capture as delivered whenever a later one succeeded, and
    /// that capture's audio would then be withheld from recovery. Claims of
    /// *other* processes are never touched either — this process cannot know
    /// what became of their transcripts.
    public func markDelivered(recording: UUID) {
        self.mutate(recording) { claim in
            guard claim.owner == self.owner else { return }
            claim.deliveredTranscript = true
        }
    }

    /// Drops a claim record. Never touches the audio file — the caller does
    /// that, or more usually does not.
    public func forget(recording: UUID) {
        self.forget(recordings: [recording])
    }

    public func forget(recordings: [UUID]) {
        guard !recordings.isEmpty else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        self.migrateLegacyLocked()
        for recording in recordings {
            self.defaults?.removeObject(forKey: Self.key(for: recording))
        }
    }

    // MARK: - Private

    private static func key(for recording: UUID) -> String {
        Self.claimKeyPrefix + recording.uuidString
    }

    private func mutate(_ recording: UUID, _ body: (inout CaptureSafetyClaim) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.migrateLegacyLocked()
        guard var claim = self.loadLocked(recording) else { return }
        body(&claim)
        self.saveLocked(claim)
    }

    private func loadLocked(_ recording: UUID) -> CaptureSafetyClaim? {
        guard let data = self.defaults?.data(forKey: Self.key(for: recording)) else { return nil }
        return try? JSONDecoder().decode(CaptureSafetyClaim.self, from: data)
    }

    private func loadAllLocked() -> [CaptureSafetyClaim] {
        guard let defaults else { return [] }
        let keys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.claimKeyPrefix) }
        var claims: [CaptureSafetyClaim] = []
        for key in keys {
            // A record this process cannot decode is a record it must not act
            // on, and acting on half a picture could offer a live capture for
            // recovery. Report none rather than some.
            guard let data = defaults.data(forKey: key),
                  let claim = try? JSONDecoder().decode(CaptureSafetyClaim.self, from: data)
            else { return [] }
            claims.append(claim)
        }
        return claims.sorted { $0.startedAt < $1.startedAt }
    }

    private func saveLocked(_ claim: CaptureSafetyClaim) {
        guard let data = try? JSONEncoder().encode(claim) else { return }
        self.defaults?.set(data, forKey: Self.key(for: claim.run))
    }

    /// Moves any claims written by a previous build's single-array storage to
    /// per-claim keys. A blob this build cannot decode is dropped rather than
    /// guessed at, exactly as a per-claim record would be.
    private func migrateLegacyLocked() {
        guard let defaults, let data = defaults.data(forKey: Self.legacyStorageKey) else { return }
        defaults.removeObject(forKey: Self.legacyStorageKey)
        guard let claims = try? JSONDecoder().decode([CaptureSafetyClaim].self, from: data) else { return }
        for claim in claims where defaults.data(forKey: Self.key(for: claim.run)) == nil {
            self.saveLocked(claim)
        }
    }
}
#endif
