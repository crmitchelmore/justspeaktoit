#if !APP_STORE
import Sparkle
#endif
import SwiftUI

#if !APP_STORE
/// SwiftUI view that wraps Sparkle's check for updates action
struct CheckForUpdatesView: View {
    @StateObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel

    init(updater: SPUUpdater) {
        _checkForUpdatesViewModel = StateObject(
            wrappedValue: CheckForUpdatesViewModel(updater: updater)
        )
    }

    var body: some View {
        Button("Check for Updates…") {
            checkForUpdatesViewModel.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

/// View model that observes Sparkle's canCheckForUpdates state
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
#else
/// App Store builds receive updates through the Mac App Store.
struct CheckForUpdatesView: View {
    var body: some View {
        Button("Updates are delivered through the App Store") {}
            .disabled(true)
    }
}
#endif
