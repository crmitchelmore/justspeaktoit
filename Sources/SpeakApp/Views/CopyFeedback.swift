import AppKit
import SwiftUI

/// Transient "Copied" state shared by every copy affordance.
///
/// The state is a value type so the timing rule (a second copy restarts the
/// window rather than letting the first copy's timer clear the checkmark early)
/// can be unit tested without a view or a run loop.
struct CopyFeedbackState: Equatable {
  /// True while the confirmation (checkmark) should be shown.
  private(set) var isConfirming = false
  /// Identifies the most recent copy so stale timers can be ignored.
  private(set) var token = 0

  /// Starts a confirmation window and returns its token.
  mutating func begin() -> Int {
    token += 1
    isConfirming = true
    return token
  }

  /// Ends the confirmation window if `token` is still the current one.
  mutating func end(token: Int) {
    guard token == self.token else { return }
    isConfirming = false
  }
}

/// Shared behaviour for copy affordances: pasteboard write, VoiceOver
/// announcement, and how long the checkmark stays up.
enum CopyFeedback {
  /// How long the checkmark replaces the copy icon.
  static let confirmationDuration: Duration = .milliseconds(1200)

  /// Writes `text` to the general pasteboard.
  static func writeToPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// Tells VoiceOver the copy happened; the checkmark alone is invisible to it.
  static func announceCopied() {
    AccessibilityNotification.Announcement("Copied").post()
  }

  /// Copies `text` and announces it.
  static func copy(_ text: String) {
    writeToPasteboard(text)
    announceCopied()
  }
}

/// A copy button that briefly swaps its icon to a checkmark and announces
/// "Copied" to VoiceOver.
///
/// `copy` performs the actual pasteboard write so callers keep whatever source
/// of truth they already had; the announcement and the checkmark are handled here.
struct CopyButton: View {
  /// How the button renders its label, matching the call site it replaces.
  enum Presentation {
    case iconOnly
    case titleOnly
    case titleAndIcon
  }

  private let title: String
  private let confirmationTitle: String
  private let systemImage: String
  private let presentation: Presentation
  private let copy: () -> Void

  @State private var feedback = CopyFeedbackState()

  init(
    title: String = "Copy",
    confirmationTitle: String = "Copied",
    systemImage: String = "doc.on.doc",
    presentation: Presentation = .iconOnly,
    copy: @escaping () -> Void
  ) {
    self.title = title
    self.confirmationTitle = confirmationTitle
    self.systemImage = systemImage
    self.presentation = presentation
    self.copy = copy
  }

  var body: some View {
    Button {
      copy()
      CopyFeedback.announceCopied()
      let token = feedback.begin()
      Task { @MainActor in
        try? await Task.sleep(for: CopyFeedback.confirmationDuration)
        feedback.end(token: token)
      }
    } label: {
      label
    }
    .accessibilityLabel(feedback.isConfirming ? confirmationTitle : title)
    .animation(.easeInOut(duration: 0.15), value: feedback.isConfirming)
  }

  @ViewBuilder
  private var label: some View {
    let currentTitle = feedback.isConfirming ? confirmationTitle : title
    let currentImage = feedback.isConfirming ? "checkmark" : systemImage
    switch presentation {
    case .iconOnly:
      Label(currentTitle, systemImage: currentImage)
        .labelStyle(.iconOnly)
    case .titleOnly:
      Text(currentTitle)
    case .titleAndIcon:
      Label(currentTitle, systemImage: currentImage)
    }
  }
}
