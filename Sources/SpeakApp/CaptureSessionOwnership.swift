import Foundation

/// The single owner of the shared microphone recorder and live transcriber.
///
/// Normal dictation and Voice Edit both record through `AudioFileManager` and
/// `TranscriptionManager`. Asking "is the other flow busy?" at start is not
/// enough: the check and the start are separate suspensions, and each flow's
/// failure path tears down resources the other may own. Every flow therefore
/// reserves capture before touching either service and releases it only after
/// its own teardown has finished, and a flow may only cancel the shared
/// services while it holds the reservation (issue #673).
@MainActor
final class CaptureSessionOwnership {
  enum Owner: Equatable, Sendable {
    case dictation
    case voiceEdit
  }

  private(set) var owner: Owner?

  /// Claims capture for `owner`. Re-entrant for the current owner; false
  /// while another flow holds it.
  @discardableResult
  func reserve(_ owner: Owner) -> Bool {
    if let current = self.owner {
      return current == owner
    }
    self.owner = owner
    return true
  }

  /// Gives capture back. Ignored unless `owner` holds it, so a late release
  /// from a finished flow can never free a reservation the other flow took.
  func release(_ owner: Owner) {
    guard self.owner == owner else { return }
    self.owner = nil
  }

  func isHeld(by owner: Owner) -> Bool {
    self.owner == owner
  }

  /// Whether `owner` may cancel the shared recorder and live stream: only
  /// while it holds the reservation, or while nobody does.
  func mayTearDownCapture(_ owner: Owner) -> Bool {
    self.owner == nil || self.owner == owner
  }
}
