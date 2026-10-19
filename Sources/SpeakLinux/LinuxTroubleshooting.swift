import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

private struct LinuxTroubleshootingSnapshot: Sendable {
    let revision: UInt64
    let configuration: DesktopHostTroubleshootingConfiguration
    let output: LinuxTextOutputOptions
    let findings: [DesktopTroubleshooting.Finding]
}

private final class LinuxTroubleshootingState: @unchecked Sendable {
    static let shared = LinuxTroubleshootingState()
    private let lock = NSLock()
    private var value: LinuxTroubleshootingSnapshot?

    func snapshot() -> LinuxTroubleshootingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func save(_ snapshot: LinuxTroubleshootingSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        value = snapshot
    }
}

extension LinuxAppController {
    fileprivate func troubleshootingSnapshot(hint: String, revision: UInt64) -> LinuxTroubleshootingSnapshot {
        let output = textOutputOptions()
        let session = LinuxHostPlatform.session
        let configuration = troubleshootingConfiguration(
            shortcutName: LinuxHostPlatform.shortcutName,
            shortcutInstructions: hint + " " + LinuxHostPlatform.readyHint(hotKeySettings()),
            restoreClipboard: session.canUseX11Injection && output.restoreClipboard
        )
        var findings = configuration.findings
        findings.append(.init(
            id: "linux-permission-evidence", title: "Microphone and Desktop Access",
            detail: "This check does not open your microphone or request desktop access. "
                + "A detected desktop session is not proof that capture or insertion is permitted. "
                + "If either fails, review your desktop's privacy settings and the app's error message.",
            severity: .info, destination: .general, systemImage: "lock.shield"
        ))
        if session.displayServer == .unknown {
            findings.append(.init(
                id: "linux-session-unknown", title: "Desktop Session Could Not Be Identified",
                detail: "Automatic insertion and global shortcut support could not be established. "
                    + "Choose clipboard-only output if pasting into another app is unavailable.",
                severity: .warning, destination: .general, systemImage: "display"
            ))
        } else if session.displayServer == .wayland && !LinuxHostPlatform.remoteDesktopAvailable {
            findings.append(.init(
                id: "linux-portal-unavailable", title: "RemoteDesktop Portal Was Unavailable at Startup",
                detail: "Automatic insertion may be unavailable on this Wayland desktop. "
                    + "Choose clipboard-only output, or restart after changing desktop portal permissions.",
                severity: .warning, destination: .general, systemImage: "display"
            ))
        }
        findings.sort { $0.severity.priority < $1.severity.priority }
        return LinuxTroubleshootingSnapshot(
            revision: revision, configuration: configuration, output: output, findings: findings
        )
    }

    fileprivate func applyTroubleshootingFix(_ command: Int32, snapshot: LinuxTroubleshootingSnapshot) async throws {
        guard !closed, canUseHistory else {
            throw DesktopHostError(message: "Wait for the current operation before applying a fix.")
        }
        switch command {
        case Int32(JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD):
            guard textOutputOptions() == snapshot.output,
                  snapshot.findings.contains(where: { $0.fix == .keepTranscriptOnClipboard }) else {
                throw DesktopHostError(message: "Text output changed. Check again before applying this fix.")
            }
            var output = snapshot.output
            output.restoreClipboard = false
            saveTextOutput(output)
            guard textOutputOptions() == output else {
                throw DesktopHostError(message: "The clipboard preference could not be saved. Check the app status.")
            }
        case Int32(JSTI_LINUX_TROUBLESHOOTING_DISABLE_PROCESSING):
            guard snapshot.findings.contains(where: { $0.fix == .disablePostProcessing }) else {
                throw DesktopHostError(message: "This report does not offer a cleanup fix. Check again.")
            }
            try await disablePostProcessingForTroubleshooting(expected: snapshot.configuration.processing)
        default:
            throw DesktopHostError(message: "This Troubleshooting fix is not supported.")
        }
    }
}

private enum LinuxTroubleshooting {
    static func navigation(_ destination: DesktopTroubleshooting.Destination) -> (String, Int32) {
        switch destination {
        case .apiKeys: return ("Open Post-processing", Int32(JSTI_PAGE_POST_PROCESSING))
        case .shortcuts: return ("Open Keyboard", Int32(JSTI_PAGE_KEYBOARD))
        case .general, .permissions: return ("Open General", Int32(JSTI_PAGE_GENERAL))
        }
    }

    static func fixCommand(_ fix: DesktopTroubleshooting.Fix?) -> Int32 {
        switch fix {
        case .some(.keepTranscriptOnClipboard): return Int32(JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD)
        case .some(.disablePostProcessing): return Int32(JSTI_LINUX_TROUBLESHOOTING_DISABLE_PROCESSING)
        case .none: return 0
        }
    }

    static func show(_ snapshot: LinuxTroubleshootingSnapshot, summary: String) {
        let strings = LinuxWindow.Strings()
        let rows = snapshot.findings.map { finding in
            let (title, page) = navigation(finding.destination)
            return JSTILinuxTroubleshootingRow(
                title: strings.add(finding.title), detail: strings.add(finding.detail),
                status: strings.add(finding.severity == .ok ? "OK" : finding.severity.rawValue.capitalized),
                navigation_title: strings.add(title), fix_title: strings.add(finding.fix?.title ?? ""),
                navigation_page: page, fix_command: fixCommand(finding.fix)
            )
        }
        let summary = strings.add(summary)
        let result = withExtendedLifetime(strings) {
            rows.withUnsafeBufferPointer {
                jsti_troubleshooting_set_rows($0.baseAddress, $0.count, summary, snapshot.revision)
            }
        }
        if result != 0 {
            let message = "Troubleshooting could not be displayed. Choose Check again to retry."
            LinuxHostPlatform.update(message)
            if jsti_troubleshooting_set_rows(nil, 0, message, snapshot.revision) != 0 {
                LinuxHostPlatform.update("The Troubleshooting window is no longer available.")
            }
        }
    }

    static func refreshSettings(_ holder: LinuxEventContext, command: Int32) async throws {
        if command == Int32(JSTI_LINUX_TROUBLESHOOTING_KEEP_CLIPBOARD) {
            try LinuxWindow.configureTextOutput(
                await holder.controller.textOutputOptions(), hint: holder.shortcuts.hint
            )
        } else if jsti_window_set_post_processing_enabled(0) != 0 {
            throw DesktopHostError(message: "The cleanup control could not be refreshed.")
        }
    }
}

private func linuxTroubleshootingEvent(_ command: Int32, _ revision: UInt64, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let holder = Unmanaged<LinuxEventContext>.fromOpaque(context).takeUnretainedValue()
    let previous = LinuxTroubleshootingState.shared.snapshot()
    holder.enqueueSettings {
        guard revision == jsti_troubleshooting_revision() else { return }
        var summary = "Saved settings checked. Permission grants are not inferred from these checks."
        if command != Int32(JSTI_LINUX_TROUBLESHOOTING_CHECK) {
            do {
                guard let previous, revision > 0, previous.revision == revision - 1 else {
                    throw DesktopHostError(message: "The report is out of date. Check again before applying a fix.")
                }
                try await holder.controller.applyTroubleshootingFix(command, snapshot: previous)
                summary = "The requested fix was saved. The checks below reflect the saved settings."
                if revision == jsti_troubleshooting_revision() {
                    do {
                        try await LinuxTroubleshooting.refreshSettings(holder, command: command)
                    } catch {
                        summary = "The fix was saved, but its controls could not be refreshed. "
                            + "Reopen the app before editing those settings."
                        LinuxHostPlatform.update(summary)
                    }
                }
            } catch {
                summary = "Fix not applied: \(error.localizedDescription)"
                LinuxHostPlatform.update(summary)
            }
        }
        guard revision == jsti_troubleshooting_revision() else { return }
        let snapshot = await holder.controller.troubleshootingSnapshot(hint: holder.shortcuts.hint, revision: revision)
        guard revision == jsti_troubleshooting_revision() else { return }
        LinuxTroubleshootingState.shared.save(snapshot)
        LinuxTroubleshooting.show(snapshot, summary: summary)
    }
}

extension LinuxWindow {
    static func configureTroubleshooting(_ holder: LinuxEventContext) throws {
        guard jsti_troubleshooting_configure(
            linuxTroubleshootingEvent, Unmanaged.passUnretained(holder).toOpaque()
        ) == 0 else { throw DesktopHostError(message: "Troubleshooting could not be configured.") }
    }
}
