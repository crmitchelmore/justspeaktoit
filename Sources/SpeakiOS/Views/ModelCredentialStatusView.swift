#if os(iOS)
import SpeakCore
import SwiftUI

struct IOSModelCredentialStatusView: View {
    let availability: ModelCredentialAvailability
    var showsText = false

    var body: some View {
        Group {
            if showsText {
                Label(label, systemImage: systemImage)
            } else {
                Image(systemName: systemImage)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var label: String {
        switch availability {
        case .ready:
            return "Key ready"
        case .missing:
            return "Key missing"
        case .notRequired:
            return "No key needed"
        }
    }

    private var accessibilityLabel: String {
        switch availability {
        case .ready(let providerName):
            return "\(providerName) API key is set"
        case .missing(let providerName):
            return "\(providerName) API key is not set"
        case .notRequired:
            return "No API key required"
        }
    }

    private var systemImage: String {
        switch availability {
        case .ready:
            return "checkmark.circle.fill"
        case .missing:
            return "exclamationmark.triangle.fill"
        case .notRequired:
            return "lock.shield.fill"
        }
    }

    private var accessibilityIdentifier: String {
        switch availability {
        case .ready:
            return "modelCredentialStatus.ready"
        case .missing:
            return "modelCredentialStatus.missing"
        case .notRequired:
            return "modelCredentialStatus.notRequired"
        }
    }

    private var tint: Color {
        switch availability {
        case .ready:
            return .green
        case .missing:
            return .orange
        case .notRequired:
            return .secondary
        }
    }
}
#endif
