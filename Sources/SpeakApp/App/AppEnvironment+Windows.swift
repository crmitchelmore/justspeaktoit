import AppKit
import Foundation

// Main-window presentation and the app chrome around it.
extension AppEnvironment {
  /// Opens the main window on the General settings tab. This backs the status
  /// bar item's "Settings…"; the navigation target is set first so a window
  /// SwiftUI has yet to create still receives the selection when it subscribes.
  func presentSettings() {
    sidebarNavigationTarget = .settings(.general)
    presentMainWindow()
  }

  /// Opens the "System resources in use" card, which lives on the Permissions page.
  func presentSystemResourcesStatus() {
    sidebarNavigationTarget = .settings(.permissions)
    presentMainWindow()
  }

  /// Brings the main window to the front, reopening it if the app is running
  /// without any visible window. This is the guaranteed access point behind the
  /// status bar item's "Open Speak…".
  func presentMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
      window.makeKeyAndOrderFront(nil)
      return
    }
    // No visible window (e.g. menu-bar-only mode). Defer past the status menu's
    // event-tracking run loop before asking SwiftUI to reopen the main scene,
    // otherwise the openWindow action can be dropped. Fall back to fronting any
    // window SwiftUI produces.
    DispatchQueue.main.async { [weak self] in
      self?.reopenMainWindow?()
      NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }
  }

  /// Installs the status bar and keeps it in step with the visibility settings.
  func installStatusBarIfNeeded() {
    SystemResourceMonitor.shared.start(environment: self)
    chrome.installStatusBarIfNeeded()
  }
  func installMenuBar() { chrome.installMenuBar() }
  func installDockMenu() { chrome.installDockMenu() }
  func installServices() { chrome.installServices() }
  #if canImport(AppKit)
  @available(macOS 10.12.2, *)
  func installTouchBar() { chrome.installTouchBar() }
  #endif
  func createDockMenu() -> NSMenu? { chrome.createDockMenu() }
}
