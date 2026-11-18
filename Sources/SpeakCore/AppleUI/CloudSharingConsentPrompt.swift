import SwiftUI

/// The user's answer on the consent sheet.
public enum CloudSharingPromptAnswer: String, Sendable {
    case allow
    case useOnDevice
    case notNow
}

/// What the caller should do after asking.
public enum CloudSharingAuthorization: Equatable, Sendable {
    /// Already allowed, or the send stays on the device.
    case proceed
    /// The user chose on-device. The caller switches that step and does not upload.
    case useOnDevice(CloudSharingRequest)
    /// The user declined, or no interface is up to ask. Send nothing.
    case refused(CloudSharingRequest)
}

/// Presents one consent sheet at a time. A host (the app's root view) must be
/// registered; without one, `prompt` returns nil and the caller sends nothing.
@MainActor
public final class CloudSharingPromptCenter: ObservableObject {
    public static let shared = CloudSharingPromptCenter()

    @Published public private(set) var request: CloudSharingRequest?
    public private(set) var hostCount = 0

    private var pending: [(CloudSharingRequest, CheckedContinuation<CloudSharingPromptAnswer, Never>)] = []
    private var current: CheckedContinuation<CloudSharingPromptAnswer, Never>?

    public var hasHost: Bool { hostCount > 0 }

    public func registerHost() {
        hostCount += 1
    }

    public func unregisterHost() {
        hostCount = max(0, hostCount - 1)
    }

    /// Dismissing the sheet is Not now.
    public var requestBinding: Binding<CloudSharingRequest?> {
        Binding(
            get: { self.request },
            set: { newValue in
                if newValue == nil, self.request != nil { self.answer(.notNow) }
            }
        )
    }

    public func answer(_ answer: CloudSharingPromptAnswer) {
        request = nil
        let current = current
        self.current = nil
        current?.resume(returning: answer)
        showNext()
    }

    /// Asks, or returns nil when `presentsUI` is false or no host appears.
    public func prompt(_ request: CloudSharingRequest, presentsUI: Bool) async -> CloudSharingPromptAnswer? {
        guard presentsUI else { return nil }
        if !hasHost {
            let appeared = await waitForHost()
            if !appeared || Task.isCancelled { return nil }
        }
        return await withCheckedContinuation { continuation in
            pending.append((request, continuation))
            showNext()
        }
    }

    private func showNext() {
        guard current == nil, request == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        request = next.0
        current = next.1
    }

    /// Cold launches (an App Intent, a share import) need a moment for the root view.
    /// Unit tests refuse at once; they grant consent when the cloud call is what they exercise.
    private func waitForHost() async -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return hasHost }
        let ticks = 30
        for _ in 0..<ticks {
            if hasHost { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hasHost
    }
}

/// Resolves consent for one send. Already-allowed and on-device sends proceed
/// without a sheet. A refusal never uploads.
@MainActor
public enum CloudSharingPrompt {
    public static func resolve(
        modelID: String,
        purpose: ModelCredentialPurpose,
        availability: CloudSharingOnDeviceAvailability = .apple,
        presentsUI: Bool = true,
        appleSpeechMayUseAppleServers: Bool = false,
        store: CloudSharingConsentStore = .shared,
        center: CloudSharingPromptCenter = .shared
    ) async -> CloudSharingAuthorization {
        let request = CloudSharingConsent.request(
            forModel: modelID,
            purpose: purpose,
            availability: availability,
            appleSpeechMayUseAppleServers: appleSpeechMayUseAppleServers
        )
        return await resolve(request, presentsUI: presentsUI, store: store, center: center)
    }

    /// Asks for a request the caller already built. Nil proceeds.
    public static func resolve(
        _ request: CloudSharingRequest?,
        presentsUI: Bool = true,
        store: CloudSharingConsentStore = .shared,
        center: CloudSharingPromptCenter = .shared
    ) async -> CloudSharingAuthorization {
        guard let request else { return .proceed }
        if store.allows(request) { return .proceed }
        guard let answer = await center.prompt(request, presentsUI: presentsUI) else {
            return .refused(request)
        }
        switch answer {
        case .allow:
            store.grant(request)
            return .proceed
        case .useOnDevice:
            guard request.canUseOnDevice else { return .refused(request) }
            return .useOnDevice(request)
        case .notNow:
            return .refused(request)
        }
    }
}

public extension View {
    /// Shows the consent sheet and marks this view as a host that can ask.
    func cloudSharingConsentPrompt() -> some View {
        modifier(CloudSharingConsentSheetModifier())
    }
}

private struct CloudSharingConsentSheetModifier: ViewModifier {
    @ObservedObject private var center = CloudSharingPromptCenter.shared

    func body(content: Content) -> some View {
        content
            .onAppear { center.registerHost() }
            .onDisappear { center.unregisterHost() }
            .sheet(item: center.requestBinding) { request in
                CloudSharingConsentSheet(request: request, onAnswer: center.answer)
            }
    }
}

/// The consent sheet: who receives the data, a link to their policy, and Allow,
/// Use on-device instead (when that step can stay on the device) and Not now.
public struct CloudSharingConsentSheet: View {
    let request: CloudSharingRequest
    let onAnswer: (CloudSharingPromptAnswer) -> Void

    public init(request: CloudSharingRequest, onAnswer: @escaping (CloudSharingPromptAnswer) -> Void) {
        self.request = request
        self.onAnswer = onAnswer
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(request.sheetMessage)
                    .fixedSize(horizontal: false, vertical: true)
                Link(request.privacyPolicyLinkTitle, destination: request.provider.privacyPolicyURL)
                    .accessibilityIdentifier(CloudSharingConsentAutomation.privacyPolicyLink)
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button(CloudSharingConsent.allowButton) { onAnswer(.allow) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(CloudSharingConsentAutomation.allowButton)
                    if request.canUseOnDevice {
                        Button(CloudSharingConsent.useOnDeviceButton) { onAnswer(.useOnDevice) }
                            .accessibilityIdentifier(CloudSharingConsentAutomation.useOnDeviceButton)
                    }
                    Button(CloudSharingConsent.notNowButton) { onAnswer(.notNow) }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier(CloudSharingConsentAutomation.notNowButton)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(20)
            .frame(maxWidth: 480)
            .navigationTitle(request.sheetTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .accessibilityIdentifier(CloudSharingConsentAutomation.sheet)
        .accessibilityAddTraits(.isModal)
    }
}

/// The providers the user has allowed, with Withdraw. Embed under a "Cloud sharing" heading.
public struct CloudSharingConsentSettings: View {
    @State private var consent = CloudSharingConsentStore.shared.consent
    private let store: CloudSharingConsentStore

    public init(store: CloudSharingConsentStore = .shared) {
        self.store = store
        _consent = State(initialValue: store.consent)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(CloudSharingConsent.settingsExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if consent.grantedProviders.isEmpty {
                Text(CloudSharingConsent.settingsEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(consent.grantedProviders) { provider in
                    providerRow(provider)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CloudSharingConsentAutomation.settingsSection)
        .onReceive(NotificationCenter.default.publisher(for: CloudSharingConsent.didChangeNotification)) { _ in
            consent = store.consent
        }
    }

    private func providerRow(_ provider: CloudSharingProvider) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Text(consent.grantedKinds(for: provider.id).map(\.title).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(CloudSharingConsent.withdrawButton) {
                store.withdraw(providerID: provider.id)
                consent = store.consent
            }
            .accessibilityIdentifier(CloudSharingConsentAutomation.withdrawButton(providerID: provider.id))
            .accessibilityLabel("Withdraw \(provider.displayName)")
        }
    }
}
