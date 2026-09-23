import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Builds the C rows the GTK window displays. Every string is copied by the
/// adapter before the call returns.
enum LinuxWindow {
    /// Owns C strings for the duration of one call.
    final class Strings {
        private var owned: [UnsafeMutablePointer<CChar>] = []
        func add(_ value: String) -> UnsafePointer<CChar> {
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            owned.append(pointer)
            return UnsafePointer(pointer)
        }
        deinit { owned.forEach { $0.deallocate() } }
    }

    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {
        let strings = Strings()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let rows = records.map { record in
            let model = DesktopHistorySearch.modelDisplayName(for: record.modelIdentifier)
            let detail = record.failure ?? record.postProcessingFailure.map { "Post-processing failed: \($0)" }
                ?? record.displayText ?? "Recording saved; awaiting transcription."
            return JSTIHistoryRow(
                id: strings.add(record.id.uuidString),
                title: strings.add("\(formatter.string(from: record.createdAt)) · \(model)"),
                detail: strings.add(String(detail.prefix(180)).replacingOccurrences(of: "\n", with: " "))
            )
        }
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer { rows in
                selectRecord
                    ? (selected?.uuidString ?? "").withCString { jsti_window_set_history(rows.baseAddress, rows.count, $0) }
                    : jsti_window_set_history(rows.baseAddress, rows.count, nil)
            }
        }
        if result != 0 {
            _ = jsti_window_update("The history list could not be refreshed. Saved recordings remain on disk.", nil, -1)
        }
    }

    /// Model rows in global slot order, with each visible slot's picker position.
    static func modelRows(_ strings: Strings) -> [JSTIModelRow] {
        let state = DesktopHostModels.snapshot
        let order = DesktopHostModels.displayOrder(state)
        return state.entries.enumerated().map { index, entry in
            JSTIModelRow(
                id: strings.add(entry.option.id), name: strings.add(DesktopHostModels.label(for: entry)),
                is_live: entry.isLive ? 1 : 0, display_order: Int32(order[index] ?? -1)
            )
        }
    }

    static func publishModels(status: String, refreshing: Bool, selected: Int32) throws {
        let strings = Strings()
        let rows = modelRows(strings)
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer {
                jsti_window_set_model_catalog(
                    $0.baseAddress, $0.count, selected, DesktopHostModels.uiText(status), refreshing ? 1 : 0
                )
            }
        }
        guard result == 0 else { throw DesktopHostError(message: "Could not display the updated model catalogue.") }
    }

    /// Lists microphones; an unavailable saved choice keeps its own row so the
    /// app never silently switches microphones.
    static func configureMicrophones(selected: String, synthetic: Bool) -> String? {
        var devices: [(id: String, name: String)] = [("", "Default microphone")]
        var warning: String?
        if synthetic {
            devices.append(("jsti-synthetic-smoke-input", "Synthetic test microphone"))
        } else {
            do {
                devices += try LinuxAudioCapture.devices().map {
                    ($0.id, $0.name + ($0.isDefault ? " (system default)" : ""))
                }
            } catch { warning = "Microphone list unavailable: \(error.localizedDescription)" }
        }
        if !devices.contains(where: { $0.id == selected }) {
            devices.append((selected, "Previously selected microphone (unavailable)"))
        }
        let strings = Strings()
        let ids: [UnsafePointer<CChar>?] = devices.map { strings.add($0.id) }
        let names: [UnsafePointer<CChar>?] = devices.map { strings.add($0.name) }
        withExtendedLifetime(strings) {
            ids.withUnsafeBufferPointer { ids in
                names.withUnsafeBufferPointer { names in
                    _ = jsti_window_set_microphones(ids.baseAddress, names.baseAddress, ids.count, selected)
                }
            }
        }
        return warning
    }

    /// Call synchronously on the GTK thread, inside the event that needs it.
    static func displayedTranscript() throws -> String {
        var required = 0
        _ = jsti_window_transcript_snapshot(nil, 0, &required)
        guard required > 0, required <= 8_388_609 else {
            throw DesktopHostError(message: "The displayed transcript is unavailable or exceeds the 8 MiB action limit.")
        }
        var bytes = [CChar](repeating: 0, count: required)
        guard jsti_window_transcript_snapshot(&bytes, bytes.count, &required) == 0 else {
            throw DesktopHostError(message: "The displayed transcript could not be captured. Try again.")
        }
        return String(cString: bytes)
    }

    static func displayedTranscriptVariant() -> DesktopTranscriptVariant? {
        switch jsti_window_transcript_variant() {
        case 0: return .processed
        case 1: return .original
        default: return nil
        }
    }

    static func textOutput(_ options: LinuxTextOutputOptions, hint: String) {
        _ = jsti_window_set_text_output(options.method == .clipboardOnly ? 1 : 0, options.restoreClipboard ? 1 : 0, hint)
    }
}
