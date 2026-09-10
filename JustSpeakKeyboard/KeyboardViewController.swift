import SpeakCore
import SwiftUI
import UIKit

/// Hosts the compact dictation keyboard. All behaviour lives in
/// `KeyboardViewModel` (capture-path planning and engine/handoff wiring) and
/// the pure `KeyboardDictationMachine`/`KeyboardTranscriptStreamer` types in
/// SpeakCore; this controller only bridges UIKit lifecycle and the
/// `textDocumentProxy`.
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
        model.activate(
            hasFullAccess: hasFullAccess,
            documentIdentifier: textDocumentProxy.documentIdentifier,
            isSecureField: documentIsSecure,
            // `advanceToNextInputMode()` moves to the *next* enabled keyboard;
            // the model only calls back when exactly two are enabled, where
            // "next" is provably the one the user was typing on (issue #1005).
            activeInputModeCount: UITextInputMode.activeInputModes.count,
            handBack: { [weak self] in
                self?.advanceToNextInputMode()
            },
            insertText: { [weak self] text in
                self?.textDocumentProxy.insertText(text)
            },
            deleteBackward: { [weak self] in
                self?.textDocumentProxy.deleteBackward()
            },
            contextBeforeInput: { [weak self] in
                self?.textDocumentProxy.documentContextBeforeInput
            },
            contextAfterInput: { [weak self] in
                self?.textDocumentProxy.documentContextAfterInput
            }
        )
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

    /// Whether the field the proxy currently addresses collects a secret.
    ///
    /// `isSecureTextEntry` is an optional trait: hosts that never set it, and
    /// proxies the system has not populated yet, report `nil`. An unknown
    /// answer is treated as **secure**, because the two failure modes are not
    /// symmetric — guessing "not secure" can push a transcript into a password
    /// field, which is unrecoverable, while guessing "secure" only withholds
    /// delivery for that field, leaving the transcript in History and on the
    /// clipboard where the user can still reach it.
    ///
    /// It is read fresh on every host callback rather than latched at
    /// appearance: focus can move from a normal field to a password field, and
    /// a field can flip `isSecureTextEntry` under a "show password" toggle,
    /// without the keyboard ever being dismissed.
    private var documentIsSecure: Bool {
        textDocumentProxy.isSecureTextEntry ?? true
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.updateDocumentContext(
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectionChanged: false,
            isSecureField: documentIsSecure
        )
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model.updateDocumentContext(
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectionChanged: true,
            isSecureField: documentIsSecure
        )
    }

    private func updatePreferredHeight() {
        let isLandscape = view.window?.windowScene?.interfaceOrientation.isLandscape
            ?? (traitCollection.verticalSizeClass == .compact)
        let isPad = traitCollection.userInterfaceIdiom == .pad
        var height: CGFloat
        if isLandscape {
            height = isPad ? 160 : 145
        } else {
            height = isPad ? 185 : 170
        }
        if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
            height += isPad ? 70 : 55
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
