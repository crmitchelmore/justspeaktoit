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

    private let store: KeyboardHandoffStore
    private let instantSessionStore: KeyboardInstantDictationStore
    private let consumer: KeyboardHandoffConsumer
    private var requestID: UUID?
    private var currentDocumentIdentifier: UUID?
    private var pollTask: Task<Void, Never>?
    private var insertText: ((String) -> Void)?
    private var profile: KeyboardDictationProfileOption?

    /// Poll cadence while a handoff request is in flight; the keyboard mirrors
    /// interim text from the App Group record at this rate.
    private static let activePollInterval = Duration.milliseconds(120)
    /// Slower cadence while nothing is in flight, so an idle keyboard stays
    /// well inside the extension CPU budget.
    private static let idlePollInterval = Duration.milliseconds(500)

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
        insertText: @escaping (String) -> Void
    ) {
        self.currentDocumentIdentifier = documentIdentifier
        self.profile = profile
        self.insertText = insertText

        if requestID == nil {
            requestID = store.activeRecord()?.requestID
        }
        refreshInstantSession()
        refresh()
        startPolling()
        if autoStart, requestID == nil, isInstantReady, presentation != .inserted {
            start()
        } else if requestID == nil, !isInstantReady {
            presentation = .waitingForApp
        }
    }

    func deactivate() {
        if let requestID,
           let phase = store.record(matching: requestID)?.phase,
           phase == .requested || phase == .recording
               || phase == .finishRequested || phase == .transcribing {
            _ = try? store.cancel(requestID: requestID)
            KeyboardHandoffSignal.postRequestChanged()
            self.requestID = nil
        }
        pollTask?.cancel()
        pollTask = nil
        liveTranscript = ""
        presentation = .idle
    }

    func updateDocumentContext(documentIdentifier: UUID, selectionChanged: Bool) {
        currentDocumentIdentifier = documentIdentifier

        guard let requestID,
              let record = store.record(matching: requestID),
              record.phase == .requested
                  || record.phase == .recording
                  || record.phase == .finishRequested
                  || record.phase == .transcribing,
              selectionChanged || record.targetDocumentIdentifier != documentIdentifier else {
            return
        }
        _ = try? store.cancel(requestID: requestID)
        KeyboardHandoffSignal.postRequestChanged()
        self.requestID = nil
        liveTranscript = ""
        presentation = .targetChanged
    }

    func start() {
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
            liveTranscript = ""
            presentation = .starting
            KeyboardHandoffSignal.postRequestChanged()
        } catch {
            presentation = .unavailable
        }
    }

    func cancel() {
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
                let interval: Duration
                if let self {
                    self.refresh()
                    interval = self.requestID == nil
                        ? Self.idlePollInterval
                        : Self.activePollInterval
                } else {
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func refresh() {
        refreshInstantSession()
        guard let requestID else {
            if isInstantReady, presentation == .waitingForApp {
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
            presentation = .error(.timedOut)
            self.requestID = nil
            return
        }
        liveTranscript = record.interimTranscript ?? ""

        if let target = record.targetDocumentIdentifier,
           target != currentDocumentIdentifier {
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
                insert: insertText
            ) {
                self.requestID = nil
                liveTranscript = ""
                presentation = .inserted
            }
        case .cancelled:
            self.requestID = nil
            presentation = .cancelled
        case .failed:
            self.requestID = nil
            presentation = .error(record.failureCode ?? .unknown)
        }
    }

    private func refreshInstantSession() {
        isInstantReady = instantSessionStore.activeSession() != nil
    }
}
