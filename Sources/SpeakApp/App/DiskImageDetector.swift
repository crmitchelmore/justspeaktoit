import Foundation

/// Decides whether the running bundle was launched from an installer disk
/// image rather than a real install location.
///
/// A `/Volumes/` path prefix on its own is not evidence of a disk image:
/// external drives and secondary APFS volumes mount there too, and a debug
/// build living on one must not be nagged to move to Applications. Installer
/// DMGs mount read-only, and Gatekeeper's App Translocation runs quarantined
/// bundles from a read-only image under `AppTranslocation`, so those are the
/// signals used here.
enum DiskImageDetector {
    static func isRunningFromDiskImage(
        bundleURL: URL,
        volumeIsReadOnly: (URL) -> Bool? = { url in
            try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly
        }
    ) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        if path.hasPrefix("/Applications/") {
            return false
        }
        if path.contains("/AppTranslocation/") {
            return true
        }
        guard path.hasPrefix("/Volumes/") else {
            return false
        }
        return volumeIsReadOnly(bundleURL) ?? false
    }
}
