import SwiftUI

/// "Send crash reports and diagnostics", bound to `DiagnosticsConsent.shared`.
/// Changing it records the decision, which starts or stops the crash reporter
/// at once through `SentryManager.observeConsent()`.
public struct DiagnosticsConsentToggle: View {
    @AppStorage(DiagnosticsConsent.defaultsKey) private var storedDecision = DiagnosticsConsentDecision.undecided
    private let showsExplanation: Bool
    private let identifier: String

    public init(showsExplanation: Bool = true, accessibilityIdentifier: String = "diagnosticsConsentToggle") {
        self.showsExplanation = showsExplanation
        self.identifier = accessibilityIdentifier
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(DiagnosticsConsent.title, isOn: binding)
                .accessibilityIdentifier(identifier)
                .accessibilityHint("Crash reports and diagnostics are sent only while this is on.")
            if showsExplanation {
                Text(DiagnosticsConsent.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { storedDecision == .granted },
            set: { DiagnosticsConsent.shared.record(granted: $0) }
        )
    }
}
