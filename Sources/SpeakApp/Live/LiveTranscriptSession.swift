import Foundation

/// Identifies a single live-transcription run for display purposes.
///
/// A recording owns exactly one of these; it is minted when the live session
/// begins and never reused, so any transcript state stamped with a previous
/// value can be recognised as stale.
struct LiveTranscriptSessionID: Hashable, Sendable {
  private let raw: UUID

  init() {
    self.raw = UUID()
  }
}

/// The complete on-screen live-transcript state for one recording.
///
/// Text, finality and confidence travel together with the owning session so a
/// consumer can never observe a mismatched combination, and so run-loop
/// deferred deliveries belonging to a finished recording can be dropped.
struct LiveTranscriptSnapshot: Equatable, Sendable {
  let sessionID: LiveTranscriptSessionID?
  let text: String
  let isFinal: Bool
  let confidence: Double?

  static let empty = LiveTranscriptSnapshot(
    sessionID: nil,
    text: "",
    isFinal: true,
    confidence: nil
  )
}

/// Decides which live-transcription controller currently owns the on-screen
/// transcript.
///
/// Live controllers are cached and reused between recordings, and their
/// WebSocket/recogniser callbacks can land after `stop()` — sometimes after the
/// *next* recording has already started. Without an owner check those late
/// events repaint the previous recording's text over the current live
/// transcript (issue #643). Display updates are therefore admitted only while a
/// session is active and only from the controller bound to that session.
///
/// The manager also checks this ownership before admitting terminal callbacks,
/// so an obsolete provider cannot complete or fail the current recording.
@MainActor
final class LiveTranscriptDisplayScope {
  private(set) var activeSessionID: LiveTranscriptSessionID?
  private var boundSource: ObjectIdentifier?

  var isActive: Bool {
    self.activeSessionID != nil
  }

  /// Starts a new display session. The session accepts nothing until a source
  /// is bound, so a late callback cannot claim ownership of it.
  @discardableResult
  func begin() -> LiveTranscriptSessionID {
    let sessionID = LiveTranscriptSessionID()
    self.activeSessionID = sessionID
    self.boundSource = nil
    return sessionID
  }

  /// Binds the controller that owns the active session. Ignored when no
  /// session is active, so a controller torn down out of order cannot revive
  /// a finished session.
  func bind(source: AnyObject) {
    guard self.isActive else { return }
    self.boundSource = ObjectIdentifier(source)
  }

  /// Detaches the current source, e.g. once a controller has stopped. The
  /// session stays open (its final transcript is still on screen) but no
  /// further updates are accepted until a source is bound again.
  func unbind() {
    self.boundSource = nil
  }

  func end() {
    self.activeSessionID = nil
    self.boundSource = nil
  }

  func accepts(_ source: AnyObject) -> Bool {
    guard self.isActive, let boundSource = self.boundSource else { return false }
    return boundSource == ObjectIdentifier(source)
  }
}

/// Identity check used by cached live controllers to drop transcript callbacks
/// emitted by a superseded stream.
///
/// Controller instances are reused across recordings, so a socket closed by the
/// previous recording can still deliver a queued message. The controller's
/// current stream object is the run identity: anything else is stale and must
/// not mutate transcript state (issue #643).
enum LiveTranscriptionRun {
  static func isCurrent(_ stream: AnyObject?, activeStream: AnyObject?) -> Bool {
    guard let stream, let activeStream else { return false }
    return stream === activeStream
  }

  /// Stand-in run identity for controllers whose stream cannot identify itself.
  ///
  /// Some local engines take their transcript callback as an argument to the
  /// stream's own initialiser, so the callback cannot capture the object it is
  /// about to create. A token is minted and published *before* the stream
  /// exists, which also closes the window in which a callback could fire before
  /// the controller has stored the stream (issue #668).
  final class Token {}
}

/// Identifies the stop/finalisation wait that currently owns a controller's
/// continuation.
///
/// Provider callbacks can finish a wait before its timeout task wakes. If a
/// second recording reaches its own stop wait first, the old timeout must not
/// resume the replacement continuation. Controllers advance this value for
/// every wait and timeout tasks act only while their captured value is current.
struct LiveTranscriptionStopGeneration {
  private var value = 0

  mutating func begin() -> Int {
    value &+= 1
    return value
  }

  func isCurrent(_ generation: Int) -> Bool {
    generation == value
  }
}
