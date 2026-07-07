import SwiftUI

/// Captures SwiftUI's `openWindow` action and gives the environment a closure to
/// reopen the main window when the app is running without a visible window
/// (menu-bar-only mode). Rendered as an invisible background of the scene so the
/// status bar item's "Open Speak…" can always bring the app back on screen.
struct MainWindowReopenBinder: View {
  let environment: AppEnvironment
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        environment.reopenMainWindow = { openWindow(id: "main") }
      }
  }
}
