import AppKit
import Combine
import Foundation
import SpeakCore

/// The app's system-chrome access points: the status bar item, the main menu,
/// the Dock menu, the Services provider and the Touch Bar. Each is installed
/// once and owned here for the life of the app.
@MainActor
final class AppChrome {
  private(set) var statusBarController: StatusBarController?
  private var statusBarVisibilityObserver: AnyCancellable?
  private(set) var menuBarManager: MenuBarManager?
  private(set) var dockMenuManager: DockMenuManager?
  private(set) var servicesProvider: ServicesProvider?
  #if canImport(AppKit)
  @available(macOS 10.12.2, *)
  private(set) var touchBarProvider: TouchBarProvider?
  #endif

  private let settings: AppSettings
  private let history: HistoryManager
  private let main: MainManager
  private let hotKeys: HotKeyManager
  private let shortcuts: ShortcutManager
  private let tts: TextToSpeechManager
  private let openMainWindow: () -> Void
  private let openSettings: () -> Void

  init(
    settings: AppSettings,
    history: HistoryManager,
    main: MainManager,
    hotKeys: HotKeyManager,
    shortcuts: ShortcutManager,
    tts: TextToSpeechManager,
    openMainWindow: @escaping () -> Void,
    openSettings: @escaping () -> Void
  ) {
    self.settings = settings
    self.history = history
    self.main = main
    self.hotKeys = hotKeys
    self.shortcuts = shortcuts
    self.tts = tts
    self.openMainWindow = openMainWindow
    self.openSettings = openSettings
  }

  /// Installs the status bar controller and the observer that keeps it in sync
  /// with the visibility settings. Safe to call more than once; it is
  /// idempotent. This is intentionally decoupled from any window lifecycle so
  /// the menu bar access point exists even when no window is on screen (for
  /// example after launching straight into menu-bar-only mode).
  func installStatusBarIfNeeded() {
    if statusBarVisibilityObserver == nil {
      statusBarVisibilityObserver = settings.$appVisibility
        .removeDuplicates()
        .combineLatest(settings.$showStatusBarIconInDockOnly.removeDuplicates())
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _ in
          self?.updateStatusBarVisibility()
        }
    }
    updateStatusBarVisibility()
  }

  /// Installs or removes the status bar icon to match the current visibility
  /// settings. In Dock Only mode the icon follows `showStatusBarIconInDockOnly`;
  /// in every mode without a Dock icon the status bar icon is always shown so
  /// the app can never end up with no access point.
  private func updateStatusBarVisibility() {
    guard settings.shouldShowStatusBarIcon else {
      statusBarController?.tearDown()
      statusBarController = nil
      return
    }
    guard statusBarController == nil else { return }
    statusBarController = StatusBarController(
      appSettings: settings,
      historyManager: history,
      mainManager: main,
      hotKeyManager: hotKeys,
      openMainWindow: openMainWindow,
      openSettings: openSettings
    )
  }

  func installMenuBar() {
    guard menuBarManager == nil else { return }
    menuBarManager = MenuBarManager(shortcutManager: shortcuts, appSettings: settings)
    menuBarManager?.setupMainMenu()
  }

  func installDockMenu() {
    guard dockMenuManager == nil else { return }
    dockMenuManager = DockMenuManager(historyManager: history)
  }

  func installServices() {
    guard servicesProvider == nil else { return }
    servicesProvider = ServicesProvider(ttsManager: tts, appSettings: settings)
    servicesProvider?.registerServices()
  }

  #if canImport(AppKit)
  @available(macOS 10.12.2, *)
  func installTouchBar() {
    touchBarProvider = TouchBarProvider(mainManager: main, ttsManager: tts, appSettings: settings)
  }
  #endif

  func createDockMenu() -> NSMenu? {
    dockMenuManager?.createDockMenu()
  }
}
