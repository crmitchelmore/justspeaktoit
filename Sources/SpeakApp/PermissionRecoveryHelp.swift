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
                         ? "All permissions are detected for this app."
                         : "Still not detected: \(remainingPermissions.joined(separator: ", ")).")
                        .accessibilityIdentifier("permissions.recheckResult")
                }
                HStack {
                    ShowRunningAppButton()
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
        // Check Again refreshes every permission, so report every one still missing;
        // never claim access is detected while any listed permission is not.
        PermissionType.availablePermissions(for: .current)
            .filter { !permissions.status(for: $0).isGranted }
            .map(\.displayName)
    }
}
