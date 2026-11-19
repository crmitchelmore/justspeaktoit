import AppKit
import Combine
import SwiftUI

/// Holds the AppEnvironment and defers its creation until after SwiftUI's graph is ready.
@MainActor
final class EnvironmentHolder: ObservableObject {
    @Published var environment: AppEnvironment?
    private var appearanceSubscription: AnyCancellable?

    func bootstrap(options: WireUp.BootstrapOptions = .default) {
        guard environment == nil else { return }
        let env = WireUp.bootstrap(options: options)
        environment = env
        // The theme is applied app-wide rather than per scene so that every
        // window, panel, menu, popover and dynamic NSColor follows it, and so
        // choosing "System" again really returns to the system appearance.
        appearanceSubscription = env.settings.$appearance.sink { appearance in
            NSApp.appearance = appearance.nsAppearance
        }
        // Install the status bar access point immediately, independent of any
        // window, so the app is always reachable — even when launched straight
        // into menu-bar-only mode with no window on screen.
        env.installStatusBarIfNeeded()
    }
}
