import AppKit
import SwiftUI

/// Tight-fitting, non-activating floating panel anchored to the top-right
/// corner of the screen for background / system-audio captures.
///
/// Unlike the full-screen standard HUD panel (`ignoresMouseEvents = true`),
/// this panel accepts clicks on the pill itself so the user can expand the
/// popover and press Stop without stealing focus from their active app.
@MainActor
final class BackgroundHUDWindowController: NSWindowController {
  private static let rightInset: CGFloat = 16
  private static let topInset: CGFloat = 12

  private let hostingController: NSHostingController<BackgroundCaptureHUDView>
  private let manager: HUDManager

  init(manager: HUDManager) {
    self.manager = manager
    let hosting = NSHostingController(rootView: BackgroundCaptureHUDView(manager: manager))
    self.hostingController = hosting

    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.hidesOnDeactivate = false
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.contentViewController = hosting

    super.init(window: panel)

    hosting.rootView = BackgroundCaptureHUDView(manager: manager) { [weak self] in
      Task { @MainActor [weak self] in
        self?.repositionToTopRight()
      }
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func present() {
    guard let window else { return }
    repositionToTopRight()
    guard !window.isVisible else { return }
    window.orderFrontRegardless()
  }

  func dismiss() {
    guard let window, window.isVisible else { return }
    window.orderOut(nil)
  }

  func repositionToTopRight() {
    guard let window else { return }
    let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
    hostingController.view.layoutSubtreeIfNeeded()
    let fittingSize = hostingController.view.fittingSize
    let width = max(120, ceil(fittingSize.width))
    let height = max(36, ceil(fittingSize.height))
    let originX = screenFrame.maxX - width - Self.rightInset
    let originY = screenFrame.maxY - height - Self.topInset
    let targetFrame = NSRect(x: originX, y: originY, width: width, height: height)
    if window.frame != targetFrame {
      window.setFrame(targetFrame, display: true)
    }
  }
}
