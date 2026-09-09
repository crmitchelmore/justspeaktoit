import AppKit
import SwiftUI

struct PermissionRecoveryHelp: View {
    @ObservedObject var permissions: PermissionsManager
    @State private var didCheck = false
    private let identity = RunningAppIdentity.current

    var body: some View {
        DisclosureGroup("Already enabled in System Settings?") {
            VStack(alignment: .leading, spacing: 8) {
                Text(identity.recoveryInstructions)
                    .fixedSize(horizontal: false, vertical: true)
                Text(identity.bundleURL.path)
                    .textSelection(.enabled)
                    .font(.caption2)
                if didCheck {
                    Text(remainingPermissions.isEmpty
                         ? "Access is detected for this app."
                         : "Still not detected: \(remainingPermissions.joined(separator: ", ")).")
                        .accessibilityIdentifier("permissions.recheckResult")
                }
                HStack {
                    Button("Show App") {
                        NSWorkspace.shared.activateFileViewerSelecting([identity.bundleURL])
                    }
                    Button("Check Again") {
                        permissions.refreshAll()
                        didCheck = true
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var remainingPermissions: [String] {
        PermissionType.availablePermissions(for: .current)
            .filter { $0.dragGuidancePane != nil && !permissions.status(for: $0).isGranted }
            .map(\.displayName)
    }
}
