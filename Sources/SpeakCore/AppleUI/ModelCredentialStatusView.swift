import SwiftUI

/// Compact key-readiness indicator shown next to a model or voice choice on
/// macOS and iOS. Apple-only: classified in Package.swift `appleCoreSources`.
public struct ModelCredentialStatusView: View {
    let availability: ModelCredentialAvailability
    var showsText: Bool

    public init(availability: ModelCredentialAvailability, showsText: Bool = false) {
        self.availability = availability
        self.showsText = showsText
    }

    public var body: some View {
        content
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            #if os(macOS)
            .help(accessibilityLabel)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if showsText {
            Label(label, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
        }
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
