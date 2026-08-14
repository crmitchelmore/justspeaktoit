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

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.updateDocumentContext(
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectionChanged: false
        )
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model.updateDocumentContext(
            documentIdentifier: textDocumentProxy.documentIdentifier,
            selectionChanged: true
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
