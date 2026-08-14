#if os(iOS)
import SwiftUI

/// Environment flag controlling whether custom-keyboard surfaces are visible.
///
/// The library defaults to `false`, so a host cannot accidentally expose setup
/// UI without deliberately enabling the matching extension build flag.
private struct IOSKeyboardEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

private struct IOSKeyboardDirectCaptureEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether the custom keyboard extension is included in this app build.
    var iOSKeyboardEnabled: Bool {
        get { self[IOSKeyboardEnabledKey.self] }
        set { self[IOSKeyboardEnabledKey.self] = newValue }
    }

    /// Whether this build permits direct capture inside the keyboard process.
    var iOSKeyboardDirectCaptureEnabled: Bool {
        get { self[IOSKeyboardDirectCaptureEnabledKey.self] }
        set { self[IOSKeyboardDirectCaptureEnabledKey.self] = newValue }
    }
}
#endif
