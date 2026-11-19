import SwiftUI

/// Asks before the first send to each cloud AI provider (App Store guideline
/// 5.1.2(i)): names every provider, lists what it would receive and links its
/// privacy policy. Allow records consent; Use on-device instead lets the host
/// switch the affected steps to on-device; Not now changes nothing.
public struct CloudSharingConsentSheet: View {
    private let requests: [CloudSharingRequest]
    private let onDeviceAvailable: Bool
    private let onAllow: () -> Void
    private let onUseOnDevice: () -> Void
    private let onNotNow: () -> Void

    public init(
        requests: [CloudSharingRequest],
        onDeviceAvailable: Bool = true,
        onAllow: @escaping () -> Void,
        onUseOnDevice: @escaping () -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.requests = requests
        self.onDeviceAvailable = onDeviceAvailable
        self.onAllow = onAllow
        self.onUseOnDevice = onUseOnDevice
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(CloudSharingConsent.sheetTitle)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("cloudSharingConsentTitle")
                    Text(CloudSharingConsent.sheetIntro(for: requests))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(requests) { request in
                        CloudSharingProviderSummary(request: request)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            buttons
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 320)
        #endif
        .accessibilityIdentifier("cloudSharingConsentSheet")
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(action: onAllow) {
                Text(CloudSharingConsent.allowTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("cloudSharingConsentAllowButton")
            .accessibilityHint("Allows the providers listed to receive this data.")

            if onDeviceAvailable {
                Button(action: onUseOnDevice) {
                    Text(CloudSharingConsent.useOnDeviceTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cloudSharingConsentOnDeviceButton")
                .accessibilityHint("Switches these steps to on-device processing so nothing is sent.")
            }

            Button(CloudSharingConsent.notNowTitle, role: .cancel, action: onNotNow)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cloudSharingConsentNotNowButton")
                .accessibilityHint("Sends nothing and changes no settings.")
        }
        .controlSize(.large)
    }
}

/// One provider: its name, the data it receives and its privacy policy link.
struct CloudSharingProviderSummary: View {
    let request: CloudSharingRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.provider.displayName)
                .font(.headline)
            ForEach(request.kindLines, id: \.self) { line in
                Label(line, systemImage: "arrow.up.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = request.provider.privacyPolicyURL {
                Link("\(request.provider.displayName) privacy policy", destination: url)
                    .font(.callout)
                    .accessibilityIdentifier("cloudSharingPrivacyPolicyLink-\(request.provider.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloudSharingProvider-\(request.provider.id)")
    }
}

/// The providers this device has allowed, each with a Withdraw button, for the
/// Privacy settings of every Apple platform. Emits plain rows so it fits in a
/// `Form` section or a `VStack`.
public struct CloudSharingConsentList: View {
    private let store: CloudSharingConsentStore
    @State private var allowed: [CloudSharingRequest] = []

    public init(store: CloudSharingConsentStore = .shared) {
        self.store = store
    }

    public var body: some View {
        Group {
            if allowed.isEmpty {
                Text(CloudSharingConsent.emptyWithdrawalText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloudSharingConsentEmpty")
            } else {
                ForEach(allowed) { request in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(request.provider.displayName)
                            Text(request.kinds.map(\.title).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Withdraw", role: .destructive) {
                            store.withdraw(providerID: request.provider.id)
                        }
                        .accessibilityLabel("Withdraw consent for \(request.provider.displayName)")
                        .accessibilityIdentifier("cloudSharingWithdrawButton-\(request.provider.id)")
                    }
                }
            }
            Text(CloudSharingConsent.withdrawalFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: CloudSharingConsentStore.didChangeNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        allowed = store.consent.allowedRequests
    }
}
