import Foundation
import SpeakDesktop

package func localCleanupState(_ row: DesktopLocalLLMStore.Row) -> Int32 {
    if row.removing { return 5 }
    if row.inUse { return 4 }
    if row.downloading { return 2 }
    switch row.state {
    case .notInstalled: return 0
    case .partial: return 1
    case .installed: return 3
    }
}

package func localCleanupDetail(_ row: DesktopLocalLLMStore.Row) -> String {
    let state: String
    switch localCleanupState(row) {
    case 1: state = "Download paused; Resume keeps the verified revision"
    case 2: state = "Downloading"
    case 3: state = "Downloaded; runtime compatibility checked on use"
    case 4: state = "In use; removal is unavailable"
    case 5: state = "Removing"
    default: state = row.metadata == nil ? "Resolve immutable metadata, then download" : "Not downloaded"
    }
    let size = row.metadata.map { "\(($0.byteCount + 1_048_575) / 1_048_576) MB" }
        ?? row.model.approximateSizeMB.map { "about \($0) MB" } ?? "Size unknown"
    let source = row.metadata.map { "\($0.repository) @ \($0.revision.prefix(12)); license: \($0.license)" }
        ?? row.model.repoID
    return "\(size). \(state). \(source). Batch only; transcript stays on this computer."
}
