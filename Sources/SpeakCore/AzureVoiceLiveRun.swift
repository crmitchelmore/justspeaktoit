import Foundation

/// One Voice Live session's state. Every field is confined to the client's
/// serial state queue. The connection, sends, deadlines, waiters and callbacks
/// belong to this run, so a late transport callback or timer from a stopped or
/// replaced run finds it closed and changes nothing.
final class AzureVoiceLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }

    /// Raw PCM stays raw in the queue; base64 and JSON exist only for the one
    /// frame in flight, so the retained expansion is bounded by a single frame.
    enum Outbound: Sendable { case sessionUpdate(String), audio(Data), commit, barrier }

    var phase: Phase
    var connection: (any StreamingWebSocketConnection)?
    /// The transport reported its handshake; nothing is sent before it.
    var didOpen = false
    /// Our configuration was handed to the transport, so the next
    /// `session.updated` can acknowledge it.
    var sessionUpdateSent = false
    /// Azure acknowledged the configuration; audio and controls may leave.
    var ready = false
    var outgoing: [Outbound] = []
    var queuedAudioBytes = 0
    var queuedAudioFrames = 0
    /// PCM in the one send in flight, still counted against the bounds.
    var inFlightAudioBytes = 0
    var sending = false
    var sendID: UInt64 = 0
    /// Every PCM byte this run admitted. A finish with none commits nothing.
    var admittedAudioBytes = 0

    /// The final commit was handed to the transport; only after that can a
    /// `committed` event or an empty-buffer answer acknowledge it.
    var commitSent = false
    /// Azure acknowledged the final commit, or no commit was needed.
    var commitAcknowledged = false
    var barrierSent = false
    /// Azure answered the barrier, so every item created by the audio and the
    /// commit before it has been announced.
    var barrierAcknowledged = false

    let sessionEventID: String
    let commitEventID: String
    let barrierEventID: String

    var transcript = AzureVoiceLiveTranscript()
    /// What the host was last shown, so updates are delivered only on change and
    /// anything a finish withheld can be delivered before a failure.
    var deliveredConfirmed = ""
    var deliveredDisplay = ""
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    init(phase: Phase) {
        self.phase = phase
        let prefix = "jsti-" + String(UUID().uuidString.lowercased().prefix(8))
        sessionEventID = prefix + "-session"
        commitEventID = prefix + "-commit"
        barrierEventID = prefix + "-barrier"
    }

    /// No send is in flight and nothing is queued.
    var isDrained: Bool { !sending && outgoing.isEmpty }

    /// The commit and the barrier are acknowledged and every announced item
    /// has completed or failed, so no more text can arrive for this recording.
    var finishIsSettled: Bool { commitAcknowledged && barrierAcknowledged && transcript.allSettled }

    /// Text a finish withheld from the host, in delivery order: the confirmed
    /// transcript as a final when it changed, then the display when it differs.
    var withheldDeliveries: [(text: String, isFinal: Bool)] {
        var deliveries: [(text: String, isFinal: Bool)] = []
        var shown = deliveredDisplay
        let confirmed = transcript.confirmed
        if !confirmed.isEmpty, confirmed != deliveredConfirmed {
            deliveries.append((confirmed, true))
            shown = confirmed
        }
        let display = transcript.display
        if !display.isEmpty, display != shown { deliveries.append((display, false)) }
        return deliveries
    }
}

/// Per-item bookkeeping for one session. Items keep the order in which they
/// were first announced, normally by `input_audio_buffer.committed`. A
/// completed transcript replaces that item's draft deltas, and the first
/// terminal event (completed or failed) wins, so a repeated completion never
/// doubles text while two identical utterances remain two items.
///
/// Confirmed text holds completed items only; display text adds the latest
/// draft of each unsettled item. The two are kept apart structurally, never by
/// prefix or length comparison.
struct AzureVoiceLiveTranscript: Equatable, Sendable {
    private(set) var order: [String] = []
    private var known: Set<String> = []
    private var drafts: [String: String] = [:]
    private var finals: [String: String] = [:]
    private var failures: Set<String> = []

    var isEmpty: Bool { order.isEmpty }
    var hasFailedItem: Bool { !failures.isEmpty }
    /// Every announced item has completed or failed.
    var allSettled: Bool { order.allSatisfy(isSettled) }

    /// Completed items in item order: the whole-session text a finish returns.
    var confirmed: String { Self.join(order.compactMap { finals[$0] }) }
    var confirmedOrNil: String? {
        let text = confirmed
        return text.isEmpty ? nil : text
    }

    /// Completed items plus the latest draft of each item still in progress.
    var display: String {
        Self.join(order.compactMap { item in finals[item] ?? (failures.contains(item) ? nil : drafts[item]) })
    }

    mutating func register(_ item: String) {
        guard known.insert(item).inserted else { return }
        order.append(item)
    }

    /// Returns `false` for an item that has already settled.
    mutating func append(delta: String, item: String) -> Bool {
        register(item)
        guard !isSettled(item) else { return false }
        drafts[item, default: ""] += delta
        return true
    }

    /// Returns `false` for a repeated or late terminal event.
    mutating func complete(_ transcript: String, item: String) -> Bool {
        register(item)
        guard !isSettled(item) else { return false }
        finals[item] = transcript
        drafts[item] = nil
        return true
    }

    /// Returns `false` for a repeated or late terminal event.
    mutating func fail(item: String) -> Bool {
        register(item)
        guard !isSettled(item) else { return false }
        failures.insert(item)
        drafts[item] = nil
        return true
    }

    private func isSettled(_ item: String) -> Bool { finals[item] != nil || failures.contains(item) }

    private static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
