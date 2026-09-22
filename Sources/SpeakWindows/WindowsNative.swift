import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakCore

struct WindowsNativeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum WindowsNative {
    static func checked(_ action: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = action(&buffer, buffer.count)
        guard result == 0 else { throw WindowsNativeError(message: String(cString: buffer)) }
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

    static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?) {
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
            let model = ModelCatalog.batchTranscription.first { $0.id == record.modelIdentifier }?.displayName
                ?? record.modelIdentifier.split(separator: "/").last.map(String.init) ?? record.modelIdentifier
            let detail = record.failure ?? record.displayText ?? "Recording saved; awaiting transcription."
            return JSTIHistoryRow(
                id: owned(record.id.uuidString), title: owned("\(formatter.string(from: record.createdAt)) · \(model)"),
                detail: owned(String(detail.prefix(180)).replacingOccurrences(of: "\n", with: " "))
            )
        }
        let result = rows.withUnsafeBufferPointer { rows in
            (selected?.uuidString ?? "").withCString { jsti_window_set_history(rows.baseAddress, rows.count, $0) }
        }
        if result != 0 { update("The history list could not be refreshed. Saved recordings remain on disk.") }
    }
}

/// Owned until WASAPI stop has joined its worker, so no callback sees freed state.
final class WindowsCaptureContext: @unchecked Sendable {
    let file: PCMRecordingFile
    let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var failed = false

    init(file: PCMRecordingFile, onFailure: @escaping @Sendable (String) -> Void) {
        self.file = file
        self.onFailure = onFailure
    }

    func fail(_ message: String) {
        lock.lock()
        let firstFailure = !failed
        failed = true
        lock.unlock()
        if firstFailure { onFailure(message) }
    }
}

func captureAudio(_ samples: UnsafePointer<Int16>?, _ count: Int, _ context: UnsafeMutableRawPointer?) {
    guard let samples, let context else { return }
    let capture = Unmanaged<WindowsCaptureContext>.fromOpaque(context).takeUnretainedValue()
    do {
        try capture.file.append(Data(bytes: samples, count: count * MemoryLayout<Int16>.size))
    } catch {
        capture.fail(error.localizedDescription)
    }
}

func captureError(_ message: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let capture = Unmanaged<WindowsCaptureContext>.fromOpaque(context).takeUnretainedValue()
    capture.fail(message.map(String.init(cString:)) ?? "Microphone capture failed.")
}
