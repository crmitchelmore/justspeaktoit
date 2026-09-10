import SpeakCore
import UIKit
import UniformTypeIdentifiers

/// The Share Sheet entry point for an existing recording (issue #1020):
/// a Voice Memo, an Apple Watch memo synced to the phone, a file in Files, an
/// audio attachment somebody sent.
///
/// It does exactly one thing — take a durable copy of the shared recording
/// into the App Group inbox while the security-scoped URL is still valid — and
/// then hands over to the app, which has the API keys, the batch client and a
/// memory budget an extension does not. Every decision it makes
/// (`SharedAudioImport`) and everywhere it puts the copy
/// (`SharedRecordingInbox`) is a pure unit tested on the host, because a
/// share extension is a terrible place to find out something was wrong: it has
/// no console the user can read and it is killed without ceremony.
///
/// **The user's recording is only ever read.** Nothing here writes to, moves,
/// renames or deletes the shared item. The only file this process removes is
/// its own partial copy when an import is cancelled or fails.
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let dismissButton = UIButton(type: .system)

    /// Read from the copy loop between chunks, on whichever thread
    /// `NSItemProvider` calls back on; set on the main actor by Cancel. A
    /// locked box rather than a bare `Bool` because those really are two
    /// different threads.
    private let cancellation = CancellationFlag()
    private var hasFinished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        Task { await run() }
    }

    // MARK: - Work

    private func run() async {
        guard let provider = Self.audioProvider(in: extensionContext?.inputItems) else {
            finish(failure: SharedAudioImportRejection.unsupportedType(fileExtension: "—"))
            return
        }
        guard let inbox = SharedRecordingInbox.shared() else {
            finish(message: "Just Speak to It can't reach its shared storage on this device, "
                + "so the recording wasn't imported. Reinstall the app and try again.",
                isSuccess: false)
            return
        }

        do {
            let item = try await importRecording(from: provider, into: inbox)
            finish(
                message: "\"\(item.originalFilename)\" is ready. Open Just Speak to It to "
                    + "transcribe it — your recording was not changed.",
                isSuccess: true
            )
        } catch {
            finish(failure: error)
        }
    }

    /// Copies the attachment into the inbox and publishes its manifest.
    ///
    /// The URL the system hands back lives only for the duration of the
    /// completion handler, so the copy happens inside it. It is streamed in
    /// 64 KiB chunks (`SharedAudioImport.stage`) rather than read into a
    /// `Data`: a two-hour Voice Memo would otherwise be enough to have this
    /// process killed for its memory footprint before it wrote anything.
    private func importRecording(
        from provider: NSItemProvider,
        into inbox: SharedRecordingInbox
    ) async throws -> SharedRecordingInboxItem {
        let cancellation = self.cancellation
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(
                forTypeIdentifier: UTType.audio.identifier
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(
                        throwing: SharedAudioImportRejection.unreadable(filename: "recording")
                    )
                    return
                }
                do {
                    continuation.resume(
                        returning: try Self.stage(url: url, into: inbox, cancellation: cancellation)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func stage(
        url: URL,
        into inbox: SharedRecordingInbox,
        cancellation: CancellationFlag
    ) throws -> SharedRecordingInboxItem {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let acceptance = try SharedAudioImport.evaluate(SharedAudioImport.inspect(fileURL: url))
        try inbox.prepare()
        let item = SharedRecordingInboxItem(
            originalFilename: acceptance.filename,
            fileExtension: acceptance.fileExtension,
            byteCount: acceptance.byteCount
        )
        let destination = inbox.stagedURL(id: item.id, fileExtension: item.fileExtension)
        try SharedAudioImport.stage(
            from: url,
            to: destination,
            // Held to the size the check above accepted: a recording that is
            // still being written must not be copied past the limit and must
            // not produce a manifest whose byte count no longer describes it.
            expectedByteCount: acceptance.byteCount,
            isCancelled: { cancellation.isCancelled }
        )
        // Manifest last: an item the app can see is an item whose bytes are
        // all present, however abruptly this process ends.
        do {
            try inbox.commit(item)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return item
    }

    /// The first attachment that is actually audio. The activation rule in
    /// `Info.plist` already keeps this extension out of the Share Sheet for
    /// anything else; this is the belt to that's braces.
    private static func audioProvider(in items: [Any]?) -> NSItemProvider? {
        let extensionItems = (items as? [NSExtensionItem]) ?? []
        for item in extensionItems {
            for provider in item.attachments ?? []
            where provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
                return provider
            }
        }
        return nil
    }

    // MARK: - Outcome

    private func finish(failure: Error) {
        let message = (failure as? LocalizedError)?.errorDescription
            ?? failure.localizedDescription
        finish(message: message, isSuccess: false)
    }

    /// Reports the outcome and leaves the sheet up until the user dismisses
    /// it. Deliberately not auto-dismissing on failure: a share sheet that
    /// closes itself is indistinguishable from one that worked, which is the
    /// exact failure mode #945 and #952 recorded.
    private func finish(message: String, isSuccess: Bool) {
        Task { @MainActor in
            guard !self.hasFinished else { return }
            self.hasFinished = true
            self.spinner.stopAnimating()
            self.statusLabel.text = message
            self.dismissButton.setTitle(isSuccess ? "Done" : "Close", for: .normal)
            self.dismissButton.isHidden = false
        }
    }

    @objc private func cancelTapped() {
        cancellation.cancel()
        // The copy loop notices between chunks, deletes its partial file and
        // throws `.cancelled`, which lands in `finish(failure:)`. If it has
        // already finished, this closes the sheet.
        if hasFinished {
            extensionContext?.cancelRequest(withError: SharedAudioImportRejection.cancelled)
        }
    }

    @objc private func dismissTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Views

    private func configureViews() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "Copying the recording…"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true

        spinner.startAnimating()

        dismissButton.setTitle("Done", for: .normal)
        dismissButton.isHidden = true
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)

        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, dismissButton, cancelButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }
}

/// A `Bool` two threads share: the copy loop reads it between chunks, the
/// Cancel button writes it on the main actor.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
