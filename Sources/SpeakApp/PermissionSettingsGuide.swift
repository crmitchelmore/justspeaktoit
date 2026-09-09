import AppKit
import Combine
import PermissionFlow
import SwiftUI

/// Owns a single, bounded guidance session. Permission state remains in PermissionsManager.
@MainActor
final class PermissionSettingsGuide: NSObject, NSWindowDelegate {
    private let flow = PermissionFlowController(configuration: .init(promptForAccessibilityTrust: false))
    private var panel: NSPanel?
    private var refreshTask: Task<Void, Never>?
    private var dragPanelCloseObserver: AnyCancellable?

    func show(_ permission: PermissionType, permissions: PermissionsManager) {
        close()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let pane = permission.dragGuidancePane,
           permission.usesDragGuide(status: permissions.status(for: permission), reduceMotion: reduceMotion),
           Bundle.main.bundleURL.pathExtension == "app" {
            let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let mouse = NSEvent.mouseLocation
            flow.authorize(
                pane: pane,
                suggestedAppURLs: [Bundle.main.bundleURL],
                sourceFrameInScreen: CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
            )
            // PermissionFlow 2.11.2 creates its panel synchronously but exposes
            // no dismissal callback. Observe only the panel this call created.
            if let dragPanel = NSApp.windows.first(where: {
                $0 is NSPanel && !existingWindows.contains(ObjectIdentifier($0))
            }) {
                dragPanelCloseObserver = NotificationCenter.default.publisher(
                    for: NSWindow.willCloseNotification, object: dragPanel
                ).sink { [weak self] _ in self?.stopPolling() }
            }
        } else {
            NSWorkspace.shared.open(permission.settingsURL)
            showToggleGuide(permission, permissions: permissions)
        }
        // Poll only while the guide is relevant, and never activate our app when a grant arrives.
        refreshTask = Task { [weak self, weak permissions] in
            var hasSeenSettings = false
            for _ in 0..<600 {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, let permissions else { return }
                permissions.refresh(permission)
                if permissions.status(for: permission).isGranted {
                    self.close()
                    return
                }
                let settingsIsRunning = !NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.systempreferences"
                ).isEmpty
                if hasSeenSettings && !settingsIsRunning {
                    self.close()
                    return
                }
                hasSeenSettings = hasSeenSettings || settingsIsRunning
            }
            self?.close()
        }
    }

    private func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
        dragPanelCloseObserver = nil
    }

    func close() {
        stopPolling()
        flow.closePanel()
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }

    private func showToggleGuide(_ permission: PermissionType, permissions: PermissionsManager) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Enable \(permission.displayName)"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PermissionToggleGuideView(
            permission: permission, permissions: permissions, onClose: { [weak self] in self?.close() }
        ))
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - 400, y: visible.maxY - 24))
        } else {
            panel.center()
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }
}

extension PermissionType {
    func usesDragGuide(status: PermissionStatus, reduceMotion: Bool) -> Bool {
        dragGuidancePane != nil && status != .restricted && !reduceMotion
    }

    var dragGuidancePane: PermissionFlowPane? {
        switch self {
        case .accessibility: return .accessibility
        case .inputMonitoring: return .inputMonitoring
        case .microphone, .speechRecognition: return nil
        }
    }

    func settingsInstructions(appName: String, status: PermissionStatus) -> String {
        if status == .restricted {
            return "This permission is restricted. Check Screen Time or ask your Mac administrator "
                + "to allow access."
        }
        if dragGuidancePane != nil {
            return "Turn on \(appName) in the app list. If it is missing, click + and select the running app. "
                + "Unlock with your password or Touch ID if asked. "
                + "If this exact app is already enabled but access is still not detected, "
                + "turn its switch off and on, then quit and reopen \(appName)."
        }
        if status == .notDetermined {
            return "Turn on the switch next to \(appName). If the app is missing, return to \(appName) "
                + "and choose Request to show the macOS prompt."
        }
        return "Turn on the switch next to \(appName). If it is missing, quit and reopen \(appName), "
            + "then check this pane again. macOS will not repeat a permission prompt after a denial."
    }
}

struct PermissionToggleGuideView: View {
    let permission: PermissionType
    @ObservedObject var permissions: PermissionsManager
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var demonstrateEnabled = false

    private var appName: String {
        // Match Finder/System Settings and the library's drag card, including Dev/Alpha bundles.
        RunningAppIdentity.current.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(permission.displayName, systemImage: permission.systemIconName)
                .font(.title2.bold())
            Text("System Settings → Privacy & Security → \(permission.displayName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if permissions.status(for: permission) != .restricted {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().frame(width: 32, height: 32)
                    Text(appName).fontWeight(.medium)
                    Spacer()
                    Toggle("Enable access", isOn: .constant(demonstrateEnabled || reduceMotion))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .allowsHitTesting(false)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: demonstrateEnabled)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("In System Settings, turn on the switch next to \(appName)")
                Text("Example — use the switch in System Settings")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(permission.settingsInstructions(appName: appName, status: permissions.status(for: permission)))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") { NSWorkspace.shared.open(permission.settingsURL) }
                if permission.dragGuidancePane != nil {
                    Button("Show App") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
                Spacer()
                Button("Done", action: onClose)
            }
        }
        .padding(20)
        .frame(width: 380)
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                demonstrateEnabled.toggle()
            }
        }
    }
}
