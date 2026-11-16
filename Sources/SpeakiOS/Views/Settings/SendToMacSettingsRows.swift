#if os(iOS)
import SpeakCore
import SwiftUI

/// Rows for Settings › Sync & Transfer › Send to Mac: the paired Mac, the Macs
/// found nearby, pairing and forgetting.
struct SendToMacSettingsRows: View {
    @ObservedObject private var sender = SendToMacService.shared
    @StateObject private var discovery = MacDiscovery()
    @State private var pairingTarget: MacDiscovery.DiscoveredMac?
    @State private var confirmingForget = false

    var body: some View {
        statusRow
            .task { await sender.load() }
            .onAppear(perform: updateDiscovery)
            .onDisappear { discovery.stopSearching() }
            .onChange(of: sender.pairedMacName) { _, _ in updateDiscovery() }
            .sheet(item: $pairingTarget) { mac in
                SendToMacPairingSheet(mac: mac)
            }
            .confirmationDialog(
                "Forget \(sender.pairedMacName ?? "this Mac")?",
                isPresented: $confirmingForget,
                titleVisibility: .visible
            ) {
                Button("Forget Mac", role: .destructive) { sender.forget() }
                    .accessibilityIdentifier("sendToMacForgetConfirmButton")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("To send again, pair with the code shown on the Mac.")
            }

        if sender.isPaired {
            Button(role: .destructive) {
                confirmingForget = true
            } label: {
                Label("Forget This Mac", systemImage: "xmark.circle")
            }
            .disabled(sender.isBusy)
            .accessibilityHint("Deletes the pairing from \(DeviceCopy.thisDevice).")
            .accessibilityIdentifier("sendToMacForgetButton")
        } else if sender.isLoaded {
            nearbyMacRows
        }

        SendToMacActivityRow(activity: sender.activity)

        SettingsFootnote(
            "Send a finished transcript from **History** to your Mac, where it's pasted at the cursor. "
                + "The Mac needs Just Speak to It from justspeaktoit.com with **Send to Mac** on in its "
                + "General settings, on the same network as \(DeviceCopy.thisDevice)."
        )
    }

    private var statusRow: some View {
        LabeledContent {
            Text(sender.pairedMacName ?? "Not paired")
                .foregroundStyle(sender.isPaired ? .primary : .secondary)
        } label: {
            Label("Paired Mac", systemImage: "desktopcomputer")
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sendToMacPairedMac")
    }

    @ViewBuilder
    private var nearbyMacRows: some View {
        ForEach(discovery.discoveredMacs) { mac in
            Button {
                pairingTarget = mac
            } label: {
                Label("Pair with \(mac.name)", systemImage: "link")
            }
            .disabled(sender.isBusy)
            .accessibilityHint("Asks for the six-digit code shown on this Mac.")
            .accessibilityIdentifier("sendToMacPairButton-\(mac.name)")
        }

        if let failure = discovery.failureMessage {
            Label(
                "Can't look for Macs: \(failure). Allow Local Network access for Just Speak to It in Settings.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("sendToMacDiscoveryError")
        } else if discovery.discoveredMacs.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Looking for Macs with Send to Mac on…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sendToMacSearching")
        }
    }

    private func updateDiscovery() {
        if sender.isPaired {
            discovery.stopSearching()
        } else {
            discovery.startSearching()
        }
    }
}

/// Asks for the code a Mac shows and pairs with it.
struct SendToMacPairingSheet: View {
    let mac: MacDiscovery.DiscoveredMac
    @ObservedObject private var sender = SendToMacService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Six-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(.title2, design: .monospaced))
                        .focused($codeFocused)
                        .disabled(sender.isBusy)
                        .accessibilityLabel("Pairing code")
                        .accessibilityIdentifier("sendToMacPairingCodeField")
                } footer: {
                    Text(
                        "On \(mac.name), open Just Speak to It's General settings. The code is under Send to Mac. "
                            + "It's used once; \(DeviceCopy.thisDevice) then keeps its own key in the Keychain."
                    )
                }

                if case .pairing = sender.activity {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Pairing…")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sendToMacPairingProgress")
                } else if case .pairingFailed(let message) = sender.activity {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Pairing failed: \(message)")
                        .accessibilityIdentifier("sendToMacPairingError")
                }
            }
            .navigationTitle("Pair with \(mac.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sender.isBusy)
                        .accessibilityIdentifier("sendToMacPairingCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") {
                        Task {
                            if await sender.pair(with: mac.endpoint, named: mac.name, code: code) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(sender.isBusy || SendToMacSender.normalizedPairingCode(code) == nil)
                    .accessibilityHint("Pairs \(DeviceCopy.thisDevice) with \(mac.name).")
                    .accessibilityIdentifier("sendToMacPairingConfirmButton")
                }
            }
            .onAppear {
                sender.clearActivity()
                codeFocused = true
            }
        }
        .interactiveDismissDisabled(sender.isBusy)
    }
}

/// The outcome of the last pairing or send, if it is still worth showing.
struct SendToMacActivityRow: View {
    let activity: SendToMacSender.Activity

    var body: some View {
        switch activity {
        case .idle, .pairing:
            EmptyView()
        case .sending(let macName):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Sending to \(macName)…")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sendToMacSending")
        case .sent(let macName):
            Label("Sent to \(macName)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("sendToMacSent")
        case .pairingFailed(let message), .sendFailed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Send to Mac failed: \(message)")
                .accessibilityIdentifier("sendToMacError")
        }
    }
}
#endif
