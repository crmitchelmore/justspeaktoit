import SpeakCore
import SwiftUI
import UIKit

// The controller and its compact SwiftUI surface live together so every
// keyboard state and supported input-mode action remains auditable in one file.
// swiftlint:disable file_length

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardViewModel()
    private var host: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let root = KeyboardRootView(
            model: model,
            showsInputModeSwitch: needsInputModeSwitchKey,
            insertText: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            deleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            adjustCursor: { [weak self] offset in
                self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            },
            undoLastInsertion: { [weak self] text in
                self?.undoLastInsertion(text) ?? false
            },
            showInputModeList: { [weak self] button, event in
                self?.handleInputModeList(from: button, with: event)
            }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        self.host = host
        updatePreferredHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.activate(hasFullAccess: hasFullAccess)
        updateDocumentContext()
    }

    override func viewDidDisappear(_ animated: Bool) {
        model.deactivate()
        super.viewDidDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredHeight()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            self?.updatePreferredHeight()
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.activate(hasFullAccess: hasFullAccess)
        updateDocumentContext()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        updateDocumentContext()
    }

    private func updateDocumentContext() {
        model.updateDocumentContext(selectedText: textDocumentProxy.selectedText)
    }

    private func undoLastInsertion(_ text: String) -> Bool {
        guard let count = KeyboardCorrectionPlan.undoDeletionCount(
            insertedText: text,
            documentContextBeforeInput: textDocumentProxy.documentContextBeforeInput
        ) else {
            return false
        }
        for _ in 0..<count {
            textDocumentProxy.deleteBackward()
        }
        return true
    }

    private func updatePreferredHeight() {
        let isLandscape = view.window?.windowScene?.interfaceOrientation.isLandscape
            ?? (traitCollection.verticalSizeClass == .compact)
        let isPad = traitCollection.userInterfaceIdiom == .pad
        var height: CGFloat
        if isLandscape {
            height = isPad ? 250 : 235
        } else {
            height = isPad ? 320 : 300
        }
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            height += isPad ? 80 : 60
        }

        if let heightConstraint {
            guard heightConstraint.constant != height else { return }
            heightConstraint.constant = height
            return
        }
        let constraint = view.heightAnchor.constraint(equalToConstant: height)
        constraint.priority = .init(999)
        constraint.isActive = true
        heightConstraint = constraint
    }
}

@MainActor
final class KeyboardViewModel: ObservableObject {
    enum Presentation: Equatable {
        case idle
        case starting
        case waitingForApp
        case recording
        case transcribing
        case inserted
        case undone
        case missingFullAccess
        case unavailable
        case cancelled
        case error(KeyboardHandoffRecord.FailureCode)
    }

    @Published private(set) var presentation: Presentation = .idle
    @Published private(set) var hasFullAccess = false
    @Published private(set) var hasSelectedText = false
    @Published private(set) var quickSessionExpiresAt: Date?

    private let store: KeyboardHandoffStore
    private let quickSessionStore: KeyboardQuickDictationStore
    private let consumer: KeyboardHandoffConsumer
    private var requestID: UUID?
    private var pollTask: Task<Void, Never>?
    private var insertText: ((String) -> Void)?
    private var lastInsertedText: String?

    var canUndoLastInsertion: Bool {
        lastInsertedText != nil
    }

    init(
        store: KeyboardHandoffStore = .shared,
        quickSessionStore: KeyboardQuickDictationStore = .shared
    ) {
        self.store = store
        self.quickSessionStore = quickSessionStore
        self.consumer = KeyboardHandoffConsumer(store: store)
    }

    func activate(hasFullAccess: Bool) {
        self.hasFullAccess = hasFullAccess
        store.recordExtensionObservation(hasFullAccess: hasFullAccess)

        guard KeyboardLaunchPolicy.blockReason(
            hasFullAccess: hasFullAccess,
            sharedContainerAvailable: store.isAvailable
        ) == nil else {
            presentation = hasFullAccess ? .unavailable : .missingFullAccess
            return
        }

        if requestID == nil {
            requestID = store.activeRecord()?.requestID
        }
        refreshQuickSession()
        refresh()
        startPolling()
    }

    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
    }

    func updateDocumentContext(selectedText: String?) {
        hasSelectedText = !(selectedText ?? "").isEmpty
    }

    func startHandoff(insertText: @escaping (String) -> Void) {
        self.insertText = insertText
        guard KeyboardLaunchPolicy.blockReason(
            hasFullAccess: hasFullAccess,
            sharedContainerAvailable: store.isAvailable
        ) == nil else {
            presentation = hasFullAccess ? .unavailable : .missingFullAccess
            return
        }

        do {
            let request = try store.createRequest()
            requestID = request.requestID
            presentation = quickSessionExpiresAt == nil ? .waitingForApp : .starting
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

    func retry(insertText: @escaping (String) -> Void) {
        if let requestID {
            store.clear(requestID: requestID)
        }
        requestID = nil
        startHandoff(insertText: insertText)
    }

    func undoLastInsertion(perform: (String) -> Bool) {
        guard let lastInsertedText, perform(lastInsertedText) else { return }
        self.lastInsertedText = nil
        presentation = .undone
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func refresh() {
        refreshQuickSession()
        guard hasFullAccess else {
            presentation = .missingFullAccess
            return
        }
        guard let requestID else {
            if presentation != .inserted && presentation != .undone && presentation != .cancelled {
                presentation = .idle
            }
            return
        }
        guard let record = store.record(matching: requestID) else {
            presentation = .error(.timedOut)
            self.requestID = nil
            return
        }

        switch record.phase {
        case .requested:
            presentation = quickSessionExpiresAt == nil ? .waitingForApp : .starting
        case .recording:
            presentation = .recording
        case .finishRequested:
            presentation = .transcribing
        case .transcribing:
            presentation = .transcribing
        case .completed:
            guard let insertText else {
                presentation = .error(.unknown)
                return
            }
            if consumer.insertReadyResult(requestID: requestID, insert: insertText) {
                lastInsertedText = record.transcript
                self.requestID = nil
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

    private func refreshQuickSession() {
        quickSessionExpiresAt = quickSessionStore.activeSession()?.expiresAt
    }
}

private struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardViewModel
    let showsInputModeSwitch: Bool
    let insertText: (String) -> Void
    let deleteBackward: () -> Void
    let adjustCursor: (Int) -> Void
    let undoLastInsertion: (String) -> Bool
    let showInputModeList: (UIButton, UIEvent) -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 10) {
                if proxy.size.width >= 620 {
                    HStack(spacing: 22) {
                        statusCopy
                        Spacer(minLength: 12)
                        primaryControl
                    }
                } else {
                    statusCopy
                    primaryControl
                }

                if showsCorrectionControls {
                    correctionControls
                }

                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, proxy.size.width >= 620 ? 28 : 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: statusSymbol)
                .font(.headline)
                .foregroundStyle(statusTint)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("keyboardStatusDetail")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var primaryControl: some View {
        switch model.presentation {
        case .idle, .inserted, .undone, .cancelled:
            Button {
                model.startHandoff(insertText: insertText)
            } label: {
                Label(primaryButtonTitle, systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: 330, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityIdentifier("keyboardTranscribeButton")

        case .missingFullAccess:
            Text("Enable Full Access in Settings to use secure handoff.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 330, minHeight: 44)

        case .starting:
            HStack(spacing: 10) {
                ProgressView()
                Text("Starting microphone")
                    .font(.headline)
            }
            .frame(maxWidth: 330, minHeight: 52)
            .accessibilityElement(children: .combine)

        case .waitingForApp:
            Label("Open Just Speak manually", systemImage: "arrow.up.forward.app")
                .font(.headline)
                .frame(maxWidth: 330, minHeight: 52)
                .accessibilityIdentifier("keyboardOpenAppInstruction")

        case .recording:
            Button {
                model.finish()
            } label: {
                Label("Finish & Transcribe", systemImage: "stop.fill")
                    .font(.headline)
                    .frame(maxWidth: 330, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityIdentifier("keyboardFinishRecordingButton")

        case .transcribing:
            HStack(spacing: 10) {
                ProgressView()
                Text(progressLabel)
                    .font(.headline)
            }
            .frame(maxWidth: 330, minHeight: 52)
            .accessibilityElement(children: .combine)

        case .unavailable, .error:
            Button {
                model.retry(insertText: insertText)
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: 330, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("keyboardRetryButton")
        }
    }

    private var correctionControls: some View {
        HStack(spacing: 8) {
            if model.canUndoLastInsertion {
                Button {
                    model.undoLastInsertion(perform: undoLastInsertion)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Undo last transcript insertion")
                .accessibilityIdentifier("keyboardUndoInsertionButton")
            }

            Button {
                adjustCursor(-1)
            } label: {
                Image(systemName: "arrow.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Move cursor left")

            Button {
                insertText(" ")
            } label: {
                Text("Space")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("keyboardSpaceButton")

            Button {
                adjustCursor(1)
            } label: {
                Image(systemName: "arrow.right")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Move cursor right")

            Button {
                deleteBackward()
            } label: {
                Image(systemName: "delete.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Delete backward")
            .accessibilityIdentifier("keyboardDeleteButton")
        }
        .buttonStyle(.bordered)
    }

    private var bottomBar: some View {
        HStack {
            if showsInputModeSwitch {
                InputModeSwitchButton(action: showInputModeList)
                    .frame(width: 48, height: 44)
                    .accessibilityLabel("Next keyboard")
                    .accessibilityHint("Touch and hold to choose another keyboard")
            }

            Text("Audio stays in Just Speak. Temporary handoff clears; transcripts remain in History.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)

            if canCancel {
                Button("Cancel") {
                    model.cancel()
                }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 48, minHeight: 44)
                .accessibilityIdentifier("keyboardCancelButton")
            } else {
                Color.clear
                    .frame(width: showsInputModeSwitch ? 48 : 0, height: 44)
                    .accessibilityHidden(true)
            }
        }
    }

    private var canCancel: Bool {
        switch model.presentation {
        case .starting, .waitingForApp, .recording, .transcribing:
            return true
        default:
            return false
        }
    }

    private var showsCorrectionControls: Bool {
        switch model.presentation {
        case .idle, .inserted, .undone, .cancelled:
            return true
        default:
            return false
        }
    }

    private var primaryButtonTitle: String {
        if model.hasSelectedText {
            return "Replace Selection by Voice"
        }
        switch model.presentation {
        case .inserted:
            return "Speak Again"
        default:
            return model.quickSessionExpiresAt == nil ? "Prepare Quick Dictation" : "Speak"
        }
    }

    private var title: String {
        switch model.presentation {
        case .idle:
            return model.quickSessionExpiresAt == nil
                ? "Quick Dictation needs preparation"
                : "Quick Dictation ready"
        case .starting: return "Starting in the keyboard"
        case .waitingForApp: return "Open Just Speak"
        case .recording: return "Recording in Just Speak"
        case .transcribing: return "Finishing transcript"
        case .inserted: return "Inserted"
        case .undone: return "Insertion removed"
        case .missingFullAccess: return "Full Access is off"
        case .unavailable: return "Just Speak is unavailable"
        case .cancelled: return "Cancelled"
        case .error: return "Couldn’t insert transcript"
        }
    }

    private var detail: String {
        switch model.presentation {
        case .idle:
            if model.hasSelectedText {
                return model.quickSessionExpiresAt == nil
                    ? "The next transcript replaces the selection. Open Just Speak once to start a five-minute session."
                    : "The next transcript replaces the selection without leaving this app."
            }
            return model.quickSessionExpiresAt == nil
                ? "Open Just Speak once to start a private five-minute microphone session."
                : "Tap Speak and stay here. Idle audio is discarded until you start."
        case .starting:
            return "Stay here. Just Speak is starting the microphone in the background."
        case .waitingForApp:
            return "Open Just Speak from the Home Screen or App Switcher and enable Quick Dictation."
        case .recording:
            return "Speak now, then finish here. The containing app owns the microphone."
        case .transcribing:
            return "Your selected JustSpeakToIt model is producing the final text."
        case .inserted:
            return "Saved in Just Speak History. Select text above to dictate a replacement, or use the correction row."
        case .undone:
            return "The inserted copy was removed. The completed transcript remains in Just Speak History."
        case .missingFullAccess:
            return "Full Access is required for the App Group handoff. It never exposes surrounding text."
        case .unavailable:
            return "Open the Just Speak app once and check that the keyboard is enabled."
        case .cancelled:
            return "No transcript was inserted."
        case let .error(code):
            return errorDetail(for: code)
        }
    }

    private var statusSymbol: String {
        switch model.presentation {
        case .idle: return "waveform"
        case .starting: return "mic.badge.plus"
        case .waitingForApp: return "arrow.up.forward.app"
        case .recording: return "record.circle"
        case .transcribing: return "ellipsis.bubble"
        case .inserted: return "checkmark.circle.fill"
        case .undone: return "arrow.uturn.backward.circle.fill"
        case .missingFullAccess: return "lock.trianglebadge.exclamationmark"
        case .unavailable, .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusTint: Color {
        switch model.presentation {
        case .inserted, .undone: return .green
        case .recording: return .red
        case .missingFullAccess, .unavailable, .error: return .orange
        default: return .primary
        }
    }

    private var progressLabel: String {
        switch model.presentation {
        case .transcribing: return "Transcribing"
        default: return "Waiting"
        }
    }

    private func errorDetail(for code: KeyboardHandoffRecord.FailureCode) -> String {
        switch code {
        case .fullAccessRequired:
            return "Turn on Full Access in Settings, then try again."
        case .appUnavailable:
            return "Open Just Speak manually from the Home Screen or App Switcher, then retry."
        case .recordingUnavailable:
            return "Recording could not start. Check microphone permission in Just Speak."
        case .noSpeech:
            return "No speech was detected. Nothing was inserted."
        case .timedOut:
            return "The one-time request expired. Nothing was inserted."
        case .invalidRequest:
            return "The request did not match the active keyboard session."
        case .unknown:
            return "The temporary handoff ended safely. Completed recordings remain in History."
        }
    }
}

private struct InputModeSwitchButton: UIViewRepresentable {
    let action: (UIButton, UIEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Next keyboard"
        button.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handle(_:event:)),
            for: .allTouchEvents
        )
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}

    final class Coordinator: NSObject {
        let action: (UIButton, UIEvent) -> Void

        init(action: @escaping (UIButton, UIEvent) -> Void) {
            self.action = action
        }

        @objc func handle(_ sender: UIButton, event: UIEvent) {
            action(sender, event)
        }
    }
}
