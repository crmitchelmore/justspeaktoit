import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDWindowPresenter {
  private let manager: HUDManager
  private let windowController: HUDWindowController
  private var cancellable: AnyCancellable?

  init(manager: HUDManager, settings: AppSettings) {
    self.manager = manager
    self.windowController = HUDWindowController(manager: manager, settings: settings)
    observeSnapshot()
  }

  private func observeSnapshot() {
    cancellable = manager.$snapshot
      .receive(on: RunLoop.main)
      .sink { [weak self] snapshot in
        guard let self else { return }
        if snapshot.phase.isVisible {
          self.windowController.present()
        } else {
          self.windowController.dismiss()
        }
      }
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
    window.orderFrontRegardless()
  }

  func dismiss() {
    window?.orderOut(nil)
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
    ZStack {
      Color.clear
      HUDOverlay(manager: manager)
        .environmentObject(settings)
        .padding(.horizontal, 72)
        .padding(.bottom, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
    .ignoresSafeArea()
  }
}
