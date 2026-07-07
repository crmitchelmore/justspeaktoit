#if os(iOS)
import SwiftUI

/// Environment flag controlling whether OpenClaw surfaces (the tab bar item and
/// its Settings section) are visible.
///
/// The library defaults it to `false` so App Store builds hide OpenClaw
/// everywhere, even if the host app forgets to configure it. The app target
/// injects the real value from its build-time `SHOW_OPENCLAW_TAB` compile
/// condition, keeping every OpenClaw surface in lockstep without the library
/// having to depend on the app.
private struct OpenClawEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether OpenClaw surfaces should be shown. Injected by the app target.
    var openClawEnabled: Bool {
        get { self[OpenClawEnabledKey.self] }
        set { self[OpenClawEnabledKey.self] = newValue }
    }
}
#endif
