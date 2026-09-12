import Foundation

/// Free-space policy for Sparkle updates.
///
/// A user hit a generic Sparkle "update error" on 2026-09-02 whose real cause
/// was a full root volume: Sparkle stages the downloaded DMG under
/// `~/Library/Caches/<bundle id>/org.sparkle-project.Sparkle/` and fails deep
/// inside the download/extract pipeline, where the only thing the user sees is
/// Sparkle's generic message. Checking before the update starts turns that into
/// an actionable "free up N GB" sentence.
///
/// The arithmetic lives here, free of Sparkle and of the file system, so it can
/// be unit-tested; `UpdaterManager` supplies the appcast enclosure length and
/// the real volume capacity.
enum UpdateDiskSpacePolicy {
    /// Error domain for update problems Speak itself diagnoses (as opposed to
    /// the `SUSparkleErrorDomain` errors Sparkle raises).
    static let errorDomain = "com.justspeaktoit.update"

    /// `code` of the insufficient-free-space error.
    static let insufficientDiskSpaceCode = 1

    /// Floor for the requirement. Small enclosures still need room for the
    /// download, the extracted `.app`, and the installer's staging copy, plus
    /// whatever headroom macOS wants for its own housekeeping.
    static let minimumRequiredBytes: Int64 = 200 * 1024 * 1024

    /// Multiplier over the download size: one copy for the downloaded DMG, one
    /// for the mounted/extracted app, one for the installer's staged copy of
    /// the new bundle before it swaps it into place.
    static let enclosureMultiplier: Int64 = 3

    /// Bytes that must be free on the staging volume before an update starts.
    static func requiredBytes(for enclosureLength: UInt64) -> Int64 {
        let clamped = Int64(clamping: enclosureLength)
        // A hostile or corrupt appcast could claim a length whose triple
        // overflows; saturate rather than trap.
        let scaled = clamped.multipliedReportingOverflow(by: enclosureMultiplier)
        let needed = scaled.overflow ? Int64.max : scaled.partialValue
        return max(needed, minimumRequiredBytes)
    }

    static func hasEnoughSpace(available: Int64, required: Int64) -> Bool {
        available >= required
    }

    /// Free bytes on the volume Sparkle stages downloads on — the user caches
    /// directory, which normally lives on the boot volume but follows the home
    /// directory when that is elsewhere.
    ///
    /// Returns `nil` when the capacity cannot be read, which the caller treats
    /// as "do not block the update": a guard that cannot measure must not be
    /// the reason an update never installs.
    static func availableStagingBytes(fileManager: FileManager = .default) -> Int64? {
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let values = try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// The error shown in place of Sparkle's generic failure.
    static func insufficientSpaceError(available: Int64, required: Int64) -> NSError {
        let availableText = formatted(available)
        let requiredText = formatted(required)
        let shortfall = formatted(max(required - available, 0))
        return NSError(
            domain: errorDomain,
            code: insufficientDiskSpaceCode,
            userInfo: [
                NSLocalizedDescriptionKey: "The update was not started: there is not enough free disk space. "
                    + "\(availableText) is free and about \(requiredText) is needed to download and install it. "
                    + "Free up at least \(shortfall) and check for updates again.",
                NSLocalizedFailureReasonErrorKey: "Only \(availableText) is free on the volume where updates are "
                    + "downloaded; \(requiredText) is needed.",
                NSLocalizedRecoverySuggestionErrorKey: "Free up at least \(shortfall) of disk space, "
                    + "then choose Check for Updates again."
            ]
        )
    }

    /// Throws `insufficientSpaceError` when the staging volume cannot hold the
    /// update; returns normally when there is room, or when free space could
    /// not be measured.
    static func validateFreeSpace(
        forEnclosureLength enclosureLength: UInt64,
        availableBytes: Int64? = availableStagingBytes()
    ) throws {
        guard let availableBytes else { return }
        let required = requiredBytes(for: enclosureLength)
        guard !hasEnoughSpace(available: availableBytes, required: required) else { return }
        throw insufficientSpaceError(available: availableBytes, required: required)
    }

    private static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
