import Foundation
import SpeakCore

/// App-owned capture path: the containing app's Instant Dictation session
/// records while the keyboard drives it through nonce-scoped App Group
/// records. Used for an explicitly selected App profile and as the fallback
/// when the extension cannot run Apple Speech.
///
/// Behaviour is unchanged from keyboard v1: recording starts automatically
/// when the keyboard appears while Instant Dictation is ready, interim text is
/// mirrored from the App Group record, and the final transcript is inserted
/// exactly once after Stop.
@MainActor
final class KeyboardHandoffController: ObservableObject {
    enum Presentation: Equatable {
        case idle
        case starting
        case waitingForApp
        case recording
        case transcribing
        case inserted
        case unavailable
        case cancelled
        case targetChanged
        case error(KeyboardHandoffRecord.FailureCode)
    }

    @Published private(set) var presentation: Presentation = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var isInstantReady = false

    /// Called immediately after a completed transcript reaches the document,
    /// so the keyboard can hand itself back (issue #1005).
    var onDidInsert: (() -> Void)?

    /// Whether a keyboard-owned dictation currently owns the caret. A pending
    /// pickup chip must not compete with words the user is saying right now.
    var isInFlight: Bool {
        requestID != nil
    }

    private let store: KeyboardHandoffStore
    private let instantSessionStore: KeyboardInstantDictationStore
    private let consumer: KeyboardHandoffConsumer
    private var requestID: UUID?
    private var currentDocumentIdentifier: UUID?
    private var pollTask: Task<Void, Never>?
    private var statusObservation: KeyboardHandoffSignalObservation?
    private var insertText: ((String) -> Void)?
    private var profile: KeyboardDictationProfileOption?
    private var autoStartWhenReady = false

    /// Live streaming of the app's interims into the field (issue #1004). All
    /// of the "when to mark, when to finalise, when to clear" reasoning lives
    /// in the pure `KeyboardMarkedTextSession`; this class only performs the
    /// proxy calls it asks for.
    private var markedText: KeyboardMarkedTextSession = .init(
        streamsMarkedText: false,
        isSecureField: true
    )
    private var setMarkedText: ((String) -> Void)?
    private var unmarkText: (() -> Void)?
    private var streamsMarkedText = false
    private var isSecureField = true
    /// A `setMarkedText` of our own makes the host report a selection change.
    /// At most one such echo is swallowed per write, so a genuine caret move
    /// still abandons the stream; a host that reports more than one only makes
    /// the keyboard fall back to plain insertion, never insert in the wrong
    /// place.
    private var expectsSelectionEcho = false

    /// Safety-net poll cadence. Since #990 the containing app posts a Darwin
    /// `statusChanged` after every write the keyboard is waiting on, so the
    /// poll no longer sets the latency of a partial or of the final insertion
    /// — it only covers a dropped notification. That is why the old 120 ms
    /// in-flight tier is gone: it cost a wake-up eight times a second in an
    /// extension with a hard memory and CPU budget, to save latency that the
    /// notification now removes outright.
    private static let safetyNetPollInterval = Duration.milliseconds(500)

    init(
        store: KeyboardHandoffStore = .shared,
        instantSessionStore: KeyboardInstantDictationStore = .shared
    ) {
        self.store = store
        self.instantSessionStore = instantSessionStore
        self.consumer = KeyboardHandoffConsumer(store: store)
    }

    func activate(
        documentIdentifier: UUID,
        profile: KeyboardDictationProfileOption,
        autoStart: Bool,
        streamsMarkedText: Bool = false,
        isSecureField: Bool = true,
        insertText: @escaping (String) -> Void,
        setMarkedText: ((String) -> Void)? = nil,
        unmarkText: (() -> Void)? = nil
    ) {
        self.currentDocumentIdentifier = documentIdentifier
        self.profile = profile
        self.insertText = insertText
        self.setMarkedText = setMarkedText
        self.unmarkText = unmarkText
        self.streamsMarkedText = streamsMarkedText && setMarkedText != nil && unmarkText != nil
        self.isSecureField = isSecureField
        self.markedText = newMarkedTextSession()
        self.expectsSelectionEcho = false

        if requestID == nil {
            requestID = store.activeRecord()?.requestID
        }
        autoStartWhenReady = autoStart && requestID == nil
        if requestID == nil {
            presentation = .idle
        }
        refreshInstantSession()
        refresh()
        startPolling()
        observeStatusChanges()
        if autoStartWhenReady, requestID == nil, isInstantReady {
            start()
        } else if requestID == nil, !isInstantReady {
            presentation = .waitingForApp
        }
    }

    func deactivate() {
        // Provisional text must never outlive the keyboard that owns it. This
        // runs before anything else, and before the proxy callbacks are let
        // go, so a dismissal mid-stream takes the words back out of the field
        // rather than stranding them there underlined forever. The transcript
        // itself is not lost: #1030 keeps the request alive through dismissal
        // and the completed result is inserted on the next appearance.
        applyMarkedText(markedText.abandon())
        if let requestID,
           let phase = store.record(matching: requestID)?.phase,
           phase == .requested || phase == .recording {
            _ = try? store.cancel(requestID: requestID)
            KeyboardHandoffSignal.postRequestChanged()
            self.requestID = nil
        }
        // Stop has committed the app-owned finalisation. Keep its nonce for
        // recovery on return, but never retain an inactive document callback.
        insertText = nil
        setMarkedText = nil
        unmarkText = nil
        statusObservation = nil
        pollTask?.cancel()
        pollTask = nil
        autoStartWhenReady = false
        liveTranscript = ""
        presentation = .idle
    }

    func updateDocumentContext(documentIdentifier: UUID, selectionChanged: Bool) {
        if currentDocumentIdentifier != documentIdentifier {
            // A different field: the marked range is unaddressable from here.
            applyMarkedText(markedText.documentChanged())
        } else if selectionChanged {
            if expectsSelectionEcho {
                expectsSelectionEcho = false
            } else {
                applyMarkedText(markedText.caretMoved())
            }
        }
        currentDocumentIdentifier = documentIdentifier

        guard let requestID,
              let record = store.record(matching: requestID),
              record.phase == .requested
                  || record.phase == .recording
                  || record.phase == .finishRequested
                  || record.phase == .transcribing,
              record.targetDocumentIdentifier != documentIdentifier else {
            return
        }
        _ = try? store.cancel(requestID: requestID)
        KeyboardHandoffSignal.postRequestChanged()
        self.requestID = nil
        liveTranscript = ""
        presentation = .targetChanged
    }

    func start() {
        autoStartWhenReady = false
        do {
            guard isInstantReady, let currentDocumentIdentifier else {
                presentation = .waitingForApp
                return
            }
            let request = try store.createRequest(
                targetDocumentIdentifier: currentDocumentIdentifier,
                profile: profile
            )
            requestID = request.requestID
            // A new run gets a new ledger. An earlier run in this appearance
            // may have abandoned streaming; that verdict belonged to it.
            markedText = newMarkedTextSession()
            expectsSelectionEcho = false
            liveTranscript = ""
            presentation = .starting
            KeyboardHandoffSignal.postRequestChanged()
        } catch {
            presentation = .unavailable
        }
    }

    func cancel() {
        applyMarkedText(markedText.abandon())
        guard let requestID else {
            presentation = .idle
            return
        }
        _ = try? store.cancel(requestID: requestID)
        KeyboardHandoffSignal.postRequestChanged()
        self.requestID = nil
        liveTranscript = ""
        presentation = .cancelled
    }

    func finish() {
        guard let requestID else { return }
        do {
            try store.requestFinish(requestID: requestID)
            presentation = .transcribing
            KeyboardHandoffSignal.postRequestChanged()
        } catch {
            presentation = .error(.invalidRequest)
        }
    }

    func retry() {
        if let requestID {
            store.clear(requestID: requestID)
        }
        requestID = nil
        start()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: Self.safetyNetPollInterval)
            }
        }
    }

    /// Reads the record the moment the app says it changed, instead of on the
    /// next poll tick (issue #990). Darwin notifications carry no payload, so
    /// this is only a wake-up: the record, its nonce and its phase are still
    /// read and validated from the App Group exactly as the poll does.
    private func observeStatusChanges() {
        guard statusObservation == nil else { return }
        statusObservation = KeyboardHandoffSignal.observeStatusChanges { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func newMarkedTextSession() -> KeyboardMarkedTextSession {
        KeyboardMarkedTextSession(
            streamsMarkedText: streamsMarkedText,
            isSecureField: isSecureField
        )
    }

    /// The only place that touches the host's marked text.
    private func applyMarkedText(_ action: KeyboardMarkedTextSession.Action) {
        switch action {
        case .none:
            return
        case let .mark(text):
            expectsSelectionEcho = true
            setMarkedText?(text)
        case let .finalise(text):
            expectsSelectionEcho = false
            setMarkedText?(text)
            unmarkText?()
        case .clear:
            expectsSelectionEcho = false
            setMarkedText?("")
            unmarkText?()
        }
    }

    /// The single place the shared record is re-read: the safety-net poll
    /// tick, the Darwin wake from #990, and the tests that drive both.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func refresh() {
        refreshInstantSession()
        guard let requestID else {
            if autoStartWhenReady, isInstantReady, presentation == .waitingForApp {
                start()
                return
            }
            if presentation != .inserted
                && presentation != .cancelled
                && presentation != .targetChanged {
                presentation = isInstantReady ? .idle : .waitingForApp
            }
            return
        }
        guard let record = store.record(matching: requestID) else {
            applyMarkedText(markedText.abandon())
            presentation = .error(.timedOut)
            self.requestID = nil
            return
        }
        liveTranscript = record.interimTranscript ?? ""

        if let target = record.targetDocumentIdentifier,
           target != currentDocumentIdentifier {
            applyMarkedText(markedText.documentChanged())
            if record.phase != .completed {
                _ = try? store.cancel(requestID: requestID)
                KeyboardHandoffSignal.postRequestChanged()
                self.requestID = nil
            }
            presentation = .targetChanged
            return
        }

        switch record.phase {
        case .requested:
            presentation = isInstantReady ? .starting : .waitingForApp
        case .recording:
            applyMarkedText(markedText.interim(liveTranscript))
            presentation = .recording
        case .finishRequested, .transcribing:
            presentation = .transcribing
        case .completed:
            guard let insertText else {
                presentation = .error(.unknown)
                return
            }
            if consumer.insertReadyResult(
                requestID: requestID,
                documentIdentifier: currentDocumentIdentifier,
                // Streaming already put provisional words in the field, so the
                // final transcript replaces them in place; with nothing marked
                // — streaming off, a secure field, or an abandoned stream — it
                // is the plain insertion it has always been. Exactly one of the
                // two happens, so the words can be neither doubled nor lost.
                insert: { [weak self] text in
                    guard let self else { return }
                    switch self.markedText.finish(text) {
                    case let .finalise(final):
                        self.applyMarkedText(.finalise(final))
                    default:
                        insertText(text)
                    }
                }
            ) {
                self.requestID = nil
                liveTranscript = ""
                presentation = .inserted
                onDidInsert?()
            }
        case .cancelled:
            applyMarkedText(markedText.abandon())
            self.requestID = nil
            presentation = .cancelled
        case .failed:
            applyMarkedText(markedText.abandon())
            self.requestID = nil
            presentation = .error(record.failureCode ?? .unknown)
        }
    }

    private func refreshInstantSession() {
        isInstantReady = instantSessionStore.activeSession() != nil
    }
}
