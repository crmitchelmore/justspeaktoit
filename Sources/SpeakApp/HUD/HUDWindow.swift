import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowPresenter: NSObject {
  /// How long after the panel is ordered front before the waiting announcement
  /// is posted, so VoiceOver has handled the new window first.
  static let announcementSettleDelay: TimeInterval = 0.25

  private let manager: HUDManager
  private let windowController: HUDWindowController
  private var cancellable: AnyCancellable?
  private var presentedTimer: Timer?

  init(manager: HUDManager, settings: AppSettings) {
    self.manager = manager
    self.windowController = HUDWindowController(manager: manager, settings: settings)
    super.init()
    manager.defersAnnouncementsUntilPresented = true
    observeSnapshot()
  }

  private func observeSnapshot() {
    cancellable = manager.$snapshot
      .map(\.phase.isVisible)
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] isVisible in
        guard let self else { return }
        if isVisible {
          self.windowController.present()
          self.schedulePresentedNotification()
        } else {
          self.presentedTimer?.invalidate()
          self.presentedTimer = nil
          self.windowController.dismiss()
          self.manager.hudWindowDidDismiss()
        }
      }
  }

  private func schedulePresentedNotification() {
    presentedTimer?.invalidate()
    // Target-selector timer, as in HUDManager, to stay off the Swift concurrency runtime.
    let timer = Timer(
      timeInterval: Self.announcementSettleDelay,
      target: self,
      selector: #selector(presentedTimerFired),
      userInfo: nil,
      repeats: false
    )
    RunLoop.main.add(timer, forMode: .common)
    presentedTimer = timer
  }

  @objc private func presentedTimerFired() {
    presentedTimer = nil
    manager.hudWindowDidPresent()
  }
}

@MainActor
private final class HUDWindowController: NSWindowController {
  private let hostingController: NSHostingController<HUDWindowContent>
  // Retain references to prevent deallocation while window is alive
  private let manager: HUDManager
  private let settings: AppSettings

  init(manager: HUDManager, settings: AppSettings) {
    self.manager = manager
    self.settings = settings
    let content = HUDWindowContent(manager: manager, settings: settings)
    self.hostingController = NSHostingController(rootView: content)

    let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    let panel = NSPanel(
      contentRect: frame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.contentViewController = hostingController

    super.init(window: panel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    guard let window = window else { return }
    updateFrameIfNeeded()
    guard !window.isVisible else { return }
    window.orderFrontRegardless()
  }

  func dismiss() {
    guard let window = window, window.isVisible else { return }
    window.orderOut(nil)
  }

  private func updateFrameIfNeeded() {
    guard let screenFrame = NSScreen.main?.frame, let window = window else { return }
    if window.frame != screenFrame {
      window.setFrame(screenFrame, display: true)
    }
  }
}

private struct HUDWindowContent: View {
  @ObservedObject var manager: HUDManager
  @ObservedObject var settings: AppSettings

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      HUDOverlay(manager: manager)
        .environmentObject(settings)
        .padding(.horizontal, 72)
        .padding(.bottom, 72)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .background(Color.clear)
    .ignoresSafeArea()
  }
}
