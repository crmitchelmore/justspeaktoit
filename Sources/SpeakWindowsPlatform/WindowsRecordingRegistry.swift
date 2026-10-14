import CWindowsSupport
import Foundation
import SpeakDesktop

/// Native closed-writer qualification is separate from verified Swift identity/reload integration.
public enum WindowsRecordingRegistry {
    public static var factory: DesktopRecordingRegistryFactory {
        #if os(Windows)
        .init { _, _ in throw DesktopRecordingRegistryError.identityUnavailable }
        #else
        .init { _, _ in throw DesktopRecordingRegistryError.unsupported }
        #endif
    }

    /// Caller supplies a fresh synthetic History path beneath its owned fixture root.
    public static func runQualificationFixture(history: URL) throws {
        #if os(Windows)
        guard history.isFileURL, history.host?.isEmpty != false, history.query == nil,
              history.fragment == nil, !history.path.utf8.contains(0) else {
            throw DesktopRecordingRegistryError.foreign
        }
        var error = [CChar](repeating: 0, count: 1_024)
        let status = error.withUnsafeMutableBufferPointer {
            jsti_recording_registry_self_test(history.path, $0.baseAddress, $0.count)
        }
        guard status == 0 else {
            throw NSError(domain: "JSTIWindowsRecordingRegistry", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: String(cString: error)
            ])
        }
        #else
        throw DesktopRecordingRegistryError.unsupported
        #endif
    }
}
