import SpeakCore
import SwiftUI

/// The microphone, provider and latency summary under the full HUD while
/// recording or after a failure. At accessibility text sizes it stacks its
/// items and lets them wrap rather than clipping the enlarged captions.
struct HUDCaptureHealthRow: View {
    let health: CaptureHealthSnapshot
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let micWarning = health.noInputDevicesAvailable || health.microphonePermission == .denied
        // Use higher contrast for warning state to meet WCAG AA.
        let micColor: Color = micWarning
            ? (colorScheme == .dark ? Color.red.opacity(0.9) : Color.red)
            : .secondary
        let micIcon = micWarning ? "mic.slash.fill" : "mic.fill"
        let deviceLabel = health.noInputDevicesAvailable ? "No microphone connected" : health.inputDeviceName
        let usesAccessibilityLayout = dynamicTypeSize.isAccessibilitySize
        let rowLayout = usesAccessibilityLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        rowLayout {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: micIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(micColor)
                    .accessibilityLabel("Microphone permission: \(microphonePermissionLabel)")

                Text(health.noInputDevicesAvailable ? deviceLabel : "Preferred: \(deviceLabel)")
                    .font(.caption2)
                    .foregroundStyle(health.noInputDevicesAvailable ? micColor : .secondary)
                    .lineLimit(usesAccessibilityLayout ? 3 : 1)
                    .truncationMode(.tail)
                    .help(
                        health.noInputDevicesAvailable
                            ? "No microphone connected. Connect a microphone to record."
                            : "Preferred microphone: \(deviceLabel). Changes apply to new recording sessions."
                    )
                    .accessibilityLabel(
                        health.noInputDevicesAvailable ? deviceLabel : "Preferred microphone: \(deviceLabel)"
                    )
            }

            if !usesAccessibilityLayout {
                Text(verbatim: "·")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            Text(health.providerLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(usesAccessibilityLayout ? 3 : 1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(health.providerLabel)
                .accessibilityLabel("Transcription provider: \(health.providerLabel)")

            LatencyBadgeCompact(tier: health.latencyTier, emphasized: true)
                .layoutPriority(2)
                .accessibilityLabel("Latency: \(health.latencyTier.displayName)")
        }
        // Size to content with a compact floor: the row keeps its familiar 18pt
        // height at standard type sizes but grows (never clips) when Dynamic Type
        // enlarges the captions.
        .frame(minHeight: 18)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var microphonePermissionLabel: String {
        if health.noInputDevicesAvailable {
            return "No device"
        }
        switch health.microphonePermission {
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        default:
            return "Unknown"
        }
    }
}
