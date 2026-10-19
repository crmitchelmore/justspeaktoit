import Foundation
import CWindowsSupport
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

private struct WindowsTroubleshootingSnapshot: Sendable {
    let revision: UInt64
    let processing: DesktopPostProcessing.Options
    let output: WindowsTextOutputOptions
    let findings: [DesktopTroubleshooting.Finding]
}

private final class WindowsTroubleshootingState: @unchecked Sendable {
    static let shared = WindowsTroubleshootingState()
    private let lock = NSLock()
    private var value: WindowsTroubleshootingSnapshot?

    func save(_ snapshot: WindowsTroubleshootingSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        value = snapshot
    }

    func snapshot() -> WindowsTroubleshootingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

extension WindowsAppController {
    fileprivate func troubleshootingSnapshot(
        permissions: [WindowsPermissionRow], revision: UInt64
    ) -> WindowsTroubleshootingSnapshot {
        let processing = postProcessingOptions()
        let output = textOutputOptions()
        let enabled = processing.mode != .disabled
        var credential = DesktopTroubleshooting.Credential.available
        if DesktopTroubleshooting.requiresCredential(enabled: enabled, model: processing.modelIdentifier) {
            do {
                let key = try effects.apiKey(name: postProcessingCredential(for: processing.modelIdentifier))
                credential = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missing : .available
            } catch { credential = .unavailable }
        }
        let shortcut = hotKeySettings()
        var findings = DesktopTroubleshooting.findings(.init(
            postProcessing: .init(enabled: enabled, model: processing.modelIdentifier, credential: credential),
            shortcutName: shortcut.name, shortcutInstructions: shortcut.readyHint, restoreClipboard: output.restoreClipboard
        ))
        findings += permissions.compactMap { row in
            let item = row.item
            guard item.status == .denied || item.status == .warning || item.status == .unknown else { return nil }
            return DesktopTroubleshooting.Finding(
                id: "permission-\(item.kind.rawValue)", title: item.kind.title,
                detail: item.detail + "\r\n\r\n" + item.kind.guidance,
                severity: item.status == .denied ? .issue : .warning,
                destination: .permissions, systemImage: "lock.shield"
            )
        }
        findings.sort { $0.severity.priority < $1.severity.priority }
        return WindowsTroubleshootingSnapshot(
            revision: revision, processing: processing, output: output, findings: findings
        )
    }

    fileprivate func applyTroubleshootingFix(
        _ command: Int32, snapshot: WindowsTroubleshootingSnapshot
    ) async throws {
        guard !closed, canUseHistory else {
            throw WindowsNativeError(message: "Wait for the current operation before applying a fix.")
        }
        switch command {
        case Int32(JSTI_TROUBLESHOOTING_KEEP_CLIPBOARD.rawValue):
            guard textOutputOptions() == snapshot.output,
                  snapshot.findings.contains(where: { $0.fix == .keepTranscriptOnClipboard }) else {
                throw WindowsNativeError(message: "Text output changed. Check again before applying this fix.")
            }
            var output = snapshot.output
            output.restoreClipboard = false
            saveTextOutput(output)
            guard textOutputOptions() == output else {
                throw WindowsNativeError(message: "The clipboard preference could not be saved. Check the app status.")
            }
        case Int32(JSTI_TROUBLESHOOTING_DISABLE_PROCESSING.rawValue):
            guard postProcessingOptions() == snapshot.processing,
                  snapshot.findings.contains(where: { $0.fix == .disablePostProcessing }) else {
                throw WindowsNativeError(message: "Post-processing changed. Check again before applying this fix.")
            }
            let key: String
            do {
                key = try effects.apiKey(name: postProcessingCredential(for: snapshot.processing.modelIdentifier))
            } catch {
                throw WindowsNativeError(message: "The saved credential could not be read. No setting was changed.")
            }
            guard key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WindowsNativeError(message: "A key is now available. Check again before changing post-processing.")
            }
            await savePostProcessing(
                enabled: false, modelIdentifier: snapshot.processing.modelIdentifier,
                prompt: snapshot.processing.customPrompt ?? "", key: ""
            )
            guard postProcessingOptions().mode == .disabled else {
                throw WindowsNativeError(message: "Post-processing could not be disabled. Check the app status.")
            }
        default: throw WindowsNativeError(message: "This Troubleshooting fix is not supported.")
        }
    }
}

private enum WindowsTroubleshooting {
    static func refreshSettings(_ holder: WindowsEventContext, command: Int32) async throws {
        let context = Unmanaged.passUnretained(holder).toOpaque()
        if command == Int32(JSTI_TROUBLESHOOTING_KEEP_CLIPBOARD.rawValue) {
            let output = await holder.controller.textOutputOptions()
            try WindowsNative.configureTextOutput(output, context: context)
        } else {
            let processing = await holder.controller.postProcessingOptions()
            try WindowsNative.configurePostProcessing(processing, context: context)
        }
        try await WindowsNative.configureConfiguration(holder)
    }

    static func navigation(_ destination: DesktopTroubleshooting.Destination) -> (String, Int32) {
        switch destination {
        case .general: return ("Open General", Int32(JSTI_TROUBLESHOOTING_GENERAL.rawValue))
        case .apiKeys: return ("Open API Keys", Int32(JSTI_TROUBLESHOOTING_API_KEYS.rawValue))
        case .shortcuts: return ("Open Shortcuts", Int32(JSTI_TROUBLESHOOTING_SHORTCUTS.rawValue))
        case .permissions: return ("Open Permissions", Int32(JSTI_TROUBLESHOOTING_PERMISSIONS.rawValue))
        }
    }

    static func fix(_ fix: DesktopTroubleshooting.Fix?) -> Int32 {
        switch fix {
        case .keepTranscriptOnClipboard: return Int32(JSTI_TROUBLESHOOTING_KEEP_CLIPBOARD.rawValue)
        case .disablePostProcessing: return Int32(JSTI_TROUBLESHOOTING_DISABLE_PROCESSING.rawValue)
        case nil: return 0
        }
    }

    static func show(_ findings: [DesktopTroubleshooting.Finding], revision: UInt64, summary: String) {
        let strings = findings.flatMap { finding in
            [
                finding.title, finding.severity.rawValue.capitalized, finding.detail,
                navigation(finding.destination).0, finding.fix?.title ?? ""
            ]
        } + [summary]
        let result = withCStrings(strings) { pointers -> Int32 in
            let rows = findings.indices.map { index in
                JSTITroubleshootingRow(
                    title: pointers[index * 5], status: pointers[index * 5 + 1],
                    detail: pointers[index * 5 + 2], navigation_title: pointers[index * 5 + 3],
                    fix_title: pointers[index * 5 + 4],
                    navigation_command: navigation(findings[index].destination).1,
                    fix_command: fix(findings[index].fix), blocking: findings[index].severity == .issue ? 1 : 0
                )
            }
            return rows.withUnsafeBufferPointer {
                jsti_troubleshooting_set_rows($0.baseAddress, $0.count, pointers[pointers.count - 1], revision)
            }
        }
        if result < 0 {
            let message = "Could not show the local Troubleshooting checks. Choose Check again to retry."
            WindowsNative.update(message)
            message.withCString { _ = jsti_troubleshooting_set_rows(nil, 0, $0, revision) }
        }
    }
}

private func troubleshootingEvent(_ command: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let revision = jsti_troubleshooting_revision()
    let previous = WindowsTroubleshootingState.shared.snapshot()
    holder.enqueueSettings {
        guard revision == jsti_troubleshooting_revision() else { return }
        var summary = "Local checks complete. Choose a finding to review its details."
        if command != Int32(JSTI_TROUBLESHOOTING_CHECK.rawValue) {
            do {
                guard let previous, revision > 0, previous.revision == revision - 1 else {
                    throw WindowsNativeError(message: "The report is out of date. Check again before applying a fix.")
                }
                try await holder.controller.applyTroubleshootingFix(command, snapshot: previous)
                summary = "The selected fix was saved. The checks below reflect the saved settings."
                do {
                    try await WindowsTroubleshooting.refreshSettings(holder, command: command)
                } catch {
                    summary = "The fix was saved, but settings controls could not be refreshed. "
                        + "Reopen the app before changing those settings."
                    WindowsNative.update(summary)
                }
            } catch {
                summary = "Fix not applied: \(error.localizedDescription)"
                WindowsNative.update(summary)
            }
        }
        let permissions = await WindowsPermissions.check(holder)
        await holder.controller.setPermissionWarning(permissions.map(\.item))
        let snapshot = await holder.controller.troubleshootingSnapshot(permissions: permissions, revision: revision)
        guard revision == jsti_troubleshooting_revision() else { return }
        WindowsTroubleshootingState.shared.save(snapshot)
        WindowsTroubleshooting.show(snapshot.findings, revision: revision, summary: summary)
    }
}

extension WindowsEventContext {
    func configureTroubleshooting() throws {
        guard jsti_troubleshooting_configure(
            troubleshootingEvent, Unmanaged.passUnretained(self).toOpaque()
        ) == 0 else { throw WindowsNativeError(message: "Could not configure Troubleshooting.") }
    }
}

enum WindowsTroubleshootingSelfTest {
    private static let keepClipboard = Int32(JSTI_TROUBLESHOOTING_KEEP_CLIPBOARD.rawValue)
    private static let disableProcessing = Int32(JSTI_TROUBLESHOOTING_DISABLE_PROCESSING.rawValue)

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSTI troubleshooting self-test \(UUID().uuidString)", isDirectory: true)
        try WindowsNative.createSyntheticDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SyntheticEffects()
        let controller = try WindowsAppController(directory: root, effects: effects)
        do {
            await controller.markReadyForSelfTest()
            try await checkClipboard(controller, effects: effects)
            try await checkProcessing(controller, effects: effects)
            let snapshot = await controller.troubleshootingSnapshot(permissions: [], revision: 5)
            await controller.close()
            try await reject { try await controller.applyTroubleshootingFix(keepClipboard, snapshot: snapshot) }
            let reopened = try WindowsAppController(directory: root, effects: effects)
            let output = await reopened.textOutputOptions()
            let processing = await reopened.postProcessingOptions()
            await reopened.close()
            try require(!output.restoreClipboard && processing.mode == .disabled, "fixes did not survive restart")
        } catch {
            await controller.close()
            throw error
        }
        print("Troubleshooting settings, stale fixes, credential states and restart checks passed.")
    }

    private static func checkClipboard(_ controller: WindowsAppController, effects: SyntheticEffects) async throws {
        let unknown = WindowsPermissionRow(.init(
            kind: .microphone, status: .unknown, detail: "Synthetic permission not detected."
        ))
        let first = await controller.troubleshootingSnapshot(permissions: [unknown], revision: 1)
        try require(first.findings.contains { $0.id == "permission-microphone" && $0.severity == .warning },
                    "an unknown permission was reported as granted")
        var changed = first.output
        changed.method = .clipboardOnly
        await controller.saveTextOutput(changed)
        try await reject { try await controller.applyTroubleshootingFix(keepClipboard, snapshot: first) }
        let current = await controller.troubleshootingSnapshot(permissions: [], revision: 2)
        effects.failNextSettingsWrite()
        try await reject { try await controller.applyTroubleshootingFix(keepClipboard, snapshot: current) }
        let refused = await controller.textOutputOptions()
        try require(refused == changed, "a failed write changed the clipboard setting")
        try await controller.applyTroubleshootingFix(keepClipboard, snapshot: current)
        let saved = await controller.textOutputOptions()
        try require(!saved.restoreClipboard && saved.method == changed.method, "the clipboard fix changed other choices")
    }

    private static func checkProcessing(_ controller: WindowsAppController, effects: SyntheticEffects) async throws {
        guard let model = DesktopPostProcessing.remoteModels.first?.id else {
            throw selfTestFailure("Troubleshooting has no remote model fixture")
        }
        effects.setSyntheticAPIKey("")
        await controller.savePostProcessing(enabled: true, modelIdentifier: model, prompt: "Keep this prompt.", key: "")
        let missing = await controller.troubleshootingSnapshot(permissions: [], revision: 3)
        try require(missing.findings.contains { $0.fix == .disablePostProcessing }, "the missing key has no explicit fix")
        effects.setSyntheticAPIKey(nil)
        let unreadable = await controller.troubleshootingSnapshot(permissions: [], revision: 4)
        try require(unreadable.findings.contains {
            $0.id == "postprocessing-api-key" && $0.severity == .warning && $0.fix == nil
        }, "an unreadable credential was treated as missing")
        effects.setSyntheticAPIKey("synthetic-available-key")
        try await reject { try await controller.applyTroubleshootingFix(disableProcessing, snapshot: missing) }
        effects.setSyntheticAPIKey("")
        try await controller.applyTroubleshootingFix(disableProcessing, snapshot: missing)
        let saved = await controller.postProcessingOptions()
        try require(saved.mode == .disabled && saved.customPrompt == "Keep this prompt.", "the cleanup fix lost settings")
        try await reject { try await controller.applyTroubleshootingFix(disableProcessing, snapshot: missing) }
    }

    private static func reject(_ operation: () async throws -> Void) async throws {
        var rejected = false
        do { try await operation() } catch { rejected = true }
        try require(rejected, "a stale, failed or closed-controller fix was accepted")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw selfTestFailure("Troubleshooting: \(message)") }
    }
}
