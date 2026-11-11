import SwiftUI

#if os(macOS)
import AppKit

private final class PassthroughTooltipView: NSView {
  var tooltipText: String {
    didSet {
      applyToolTip()
    }
  }

  override init(frame frameRect: NSRect) {
    tooltipText = ""
    super.init(frame: frameRect)
    applyToolTip()
  }

  convenience init(text: String) {
    self.init(frame: .zero)
    tooltipText = text
    applyToolTip()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    applyToolTip()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    applyToolTip()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyToolTip()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    applyToolTip()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  private func applyToolTip() {
    toolTip = tooltipText.isEmpty ? nil : tooltipText
  }
}

private struct SpeakTooltipRepresentable: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> PassthroughTooltipView {
    PassthroughTooltipView(text: text)
  }

  func updateNSView(_ nsView: PassthroughTooltipView, context: Context) {
    nsView.tooltipText = text
  }
}

private struct SpeakTooltipModifier: ViewModifier {
  let text: String

  func body(content: Content) -> some View {
    content.background(SpeakTooltipRepresentable(text: text))
  }
}
#else
private struct SpeakTooltipModifier: ViewModifier {
  let text: String

  func body(content: Content) -> some View {
    content
  }
}
#endif

extension View {
  func speakTooltip(_ text: String) -> some View {
    modifier(SpeakTooltipModifier(text: text)).help(text)
  }
}
