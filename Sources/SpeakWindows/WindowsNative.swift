import Foundation
import CWindowsAutomation
import CWindowsSupport
import SpeakDesktop
import SpeakCore
import SpeakDesktopHost

enum WindowsNative {
    static func checked(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = action(&buffer, buffer.count)
        guard result == 0 else { throw WindowsNativeError(message: String(cString: buffer)) }
    }

    /// The `--self-test` checks for storage, staging, streaming, audio and the automation pipe.
    static func storageMediaAndAutomationSelfTests() throws {
        try checked { jsti_private_storage_self_test($0, $1) }
        try stagingSelfTest()
        try checked { jsti_websocket_self_test($0, $1) }
        try checked { jsti_audio_conversion_self_test($0, $1) }
        try checked { jsti_audio_playback_self_test($0, $1) }
        try checked { jsti_automation_pipe_self_test($0, $1) }
    }

    static func update(_ status: String, transcript: String? = nil, state: Int32 = -1) {
        status.withCString { statusPointer in
            if let transcript {
                transcript.withCString { _ = jsti_window_update(statusPointer, $0, state) }
            } else {
                _ = jsti_window_update(statusPointer, nil, state)
            }
        }
    }

    static func apiKey(name: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 2560)
        defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = 0
        var error = [CChar](repeating: 0, count: 1024)
        let result = jsti_credential_read(name, &buffer, buffer.count, &count, &error, error.count)
        if result == 1 { return "" }
        guard result == 0 else { throw WindowsNativeError(message: String(cString: error)) }
        guard let key = String(bytes: buffer.prefix(count), encoding: .utf8) else {
            throw WindowsNativeError(message: "The saved API key is not valid UTF-8. Save it again.")
        }
        return key
    }

    static func saveAPIKey(_ key: String, name: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            try checked { jsti_credential_delete(name, $0, $1) }
        } else {
            try Array(cleaned.utf8).withUnsafeBufferPointer { bytes in
                try checked { jsti_credential_write(name, bytes.baseAddress, bytes.count, $0, $1) }
            }
        }
    }

    static func chooseExportPath(identifier: String) throws -> String? {
        var path = [CChar](repeating: 0, count: 131_072)
        var error = [CChar](repeating: 0, count: 1024)
        let result = jsti_window_choose_export_path(
            "Transcript-\(identifier).txt", &path, path.count, &error, error.count
        )
        if result == 1 { return nil }
        guard result == 0 else { throw WindowsNativeError(message: String(cString: error)) }
        return String(cString: path)
    }

    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool = false) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { $0.deallocate() } }
        func owned(_ value: String) -> UnsafePointer<CChar> {
            let bytes = Array(value.utf8CString)
            let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let rows = records.map { record in
            // The same canonical friendly name that search matches against.
            let model = DesktopHistorySearch.modelDisplayName(for: record.modelIdentifier)
            let detail = record.failure ?? record.postProcessingFailure.map { "Post-processing failed: \($0)" }
                ?? record.displayText ?? "Recording saved; awaiting transcription."
            return JSTIHistoryRow(
                id: owned(record.id.uuidString), title: owned("\(formatter.string(from: record.createdAt)) · \(model)"),
                detail: owned(String(detail.prefix(180)).replacingOccurrences(of: "\n", with: " "))
            )
        }
        let result = rows.withUnsafeBufferPointer { rows in
            if selectRecord {
                return (selected?.uuidString ?? "").withCString {
                    jsti_window_set_history(rows.baseAddress, rows.count, $0)
                }
            }
            return jsti_window_set_history(rows.baseAddress, rows.count, nil)
        }
        if result != 0 { update("The history list could not be refreshed. Saved recordings remain on disk.") }
    }

    static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {
        let effectiveVariant: Int32 = record.hasTranscriptVariants && variant == .processed ? 0 : 1
        let selected: Int32 = record.result == nil ? -1 : effectiveVariant
        let result = record.id.uuidString.withCString { identifier in
            (record.text(for: variant) ?? "").withCString { text in
                status.withCString {
                    jsti_window_set_history_presentation(
                        identifier, selected, record.hasTranscriptVariants ? 1 : 0, text, $0
                    )
                }
            }
        }
        if result != 0 { update("The saved transcript could not be displayed.") }
    }

    static func recordingState(_ state: Int32) {
        _ = jsti_window_update(nil, nil, state)
    }

    /// Call synchronously on the window thread, before a dialog or actor hop.
    static func displayedTranscript() throws -> String {
        var count = 0
        guard jsti_window_transcript_snapshot(nil, 0, &count) == 2, count > 0, count <= 8_388_609 else {
            throw WindowsNativeError(
                message: "The displayed transcript is unavailable or exceeds the 8 MiB action limit."
            )
        }
        var bytes = [CChar](repeating: 0, count: count)
        guard jsti_window_transcript_snapshot(&bytes, bytes.count, &count) == 0 else {
            throw WindowsNativeError(message: "The displayed transcript could not be captured. Try again.")
        }
        return String(cString: bytes)
    }

    /// Reports which transcript version the window shows for `record`; the
    /// window applies it only while that record is still selected.
    static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {
        let selected: Int32 = variant.map { $0 == .original ? 1 : 0 } ?? -1
        let result = (record?.uuidString ?? "").withCString {
            jsti_window_set_transcript_variant($0, selected, switchable ? 1 : 0)
        }
        if result != 0 { update("The transcript version control could not be refreshed.") }
    }

    /// The version the window displays for the selected record. Read it
    /// synchronously inside the UI callback that carries the record ID.
    static func displayedTranscriptVariant() -> DesktopTranscriptVariant? {
        switch jsti_window_transcript_variant() {
        case 0: return .processed
        case 1: return .original
        default: return nil
        }
    }
}

func captureAudio(_ samples: UnsafePointer<Int16>?, _ count: Int, _ context: UnsafeMutableRawPointer?) {
    guard let samples, let context else { return }
    Unmanaged<WindowsCaptureContext>.fromOpaque(context).takeUnretainedValue().receive(samples, count: count)
}

func captureError(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let capture = Unmanaged<WindowsCaptureContext>.fromOpaque(context).takeUnretainedValue()
    capture.fail(message.map(String.init(cString:)) ?? "Microphone capture failed.")
}
