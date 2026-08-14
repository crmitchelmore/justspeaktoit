#if os(iOS)
import Foundation
import Network
import SpeakCore

// MARK: - Mac Discovery

/// Discovers available Speak instances on the local network via Bonjour.
@MainActor
public final class MacDiscovery: ObservableObject {
    @Published public private(set) var discoveredMacs: [DiscoveredMac] = []
    @Published public private(set) var isSearching = false
    
    private var browser: NWBrowser?
    
    public struct DiscoveredMac: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
        
        public init(id: String, name: String, endpoint: NWEndpoint) {
            self.id = id
            self.name = name
            self.endpoint = endpoint
        }
    }
    
    public init() {}
    
    public func startSearching() {
        guard browser == nil else { return }
        
        isSearching = true
        discoveredMacs = []
        
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        
        let browser = NWBrowser(
            for: .bonjour(type: SpeakTransportServiceType, domain: "local."),
            using: parameters
        )
        
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed(let error):
                    print("[MacDiscovery] Browser failed: \(error)")
                    self?.isSearching = false
                case .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                self?.handleBrowseResults(results)
            }
        }
        
        browser.start(queue: .main)
        self.browser = browser
    }
    
    public func stopSearching() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
    
    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        discoveredMacs = results.compactMap { result -> DiscoveredMac? in
            guard case .service(let name, _, _, _) = result.endpoint else {
                return nil
            }
            return DiscoveredMac(
                id: "\(result.hashValue)",
                name: name,
                endpoint: result.endpoint
            )
        }
    }
}

// MARK: - Send to Mac View

import SwiftUI

public struct SendToMacView: View {
    @StateObject private var discovery = MacDiscovery()
    @StateObject private var connection = MacConnection()
    @State private var selectedMac: MacDiscovery.DiscoveredMac?
    @State private var pairingCode = ""
    @State private var showingPairingSheet = false
    
    public init() {}
    
    public var body: some View {
        Form {
            Section {
                switch connection.state {
                case .connected:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Connected")
                                .font(.headline)
                            if let name = connection.connectedMacName {
                                Text(name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Disconnect") {
                            connection.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                    
                case .connecting, .authenticating:
                    HStack {
                        ProgressView()
                        Text(connection.state == .connecting ? "Connecting..." : "Authenticating...")
                            .padding(.leading, 8)
                    }
                    
                case .error(let message):
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                    
                case .disconnected:
                    Text("Not connected to a Mac")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Connection Status")
            }
            
            if case .disconnected = connection.state {
                Section {
                    if discovery.isSearching {
                        HStack {
                            ProgressView()
                            Text("Searching...")
                                .padding(.leading, 8)
                        }
                    }
                    
                    ForEach(discovery.discoveredMacs) { mac in
                        Button {
                            selectedMac = mac
                            showingPairingSheet = true
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(mac.name)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    if !discovery.isSearching && discovery.discoveredMacs.isEmpty {
                        ContentUnavailableView {
                            Label("No Macs Found", systemImage: "desktopcomputer")
                        } description: {
                            Text("Make sure Speak is running on your Mac and both devices are on the same network.")
                        } actions: {
                            Button("Search Again") {
                                discovery.startSearching()
                            }
                        }
                    }
                } header: {
                    Text("Available Macs")
                }
            }
        }
        .navigationTitle("Send to Mac")
        .onAppear { discovery.startSearching() }
        .onDisappear { discovery.stopSearching() }
        .sheet(isPresented: $showingPairingSheet) {
            PairingSheet(
                macName: selectedMac?.name ?? "Mac",
                pairingCode: $pairingCode,
                onPair: {
                    guard let mac = selectedMac else { return }
                    showingPairingSheet = false
                    Task {
                        await connection.connect(
                            to: mac.endpoint,
                            named: mac.name,
                            pairingCode: pairingCode
                        )
                        pairingCode = ""
                    }
                },
                onCancel: {
                    showingPairingSheet = false
                    pairingCode = ""
                }
            )
        }
    }
}

struct PairingSheet: View {
    let macName: String
    @Binding var pairingCode: String
    let onPair: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Enter the pairing code shown on \(macName)")
                        .foregroundStyle(.secondary)
                    
                    TextField("Pairing Code", text: $pairingCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospaced())
                        .multilineTextAlignment(.center)
                }
                
                Section {
                    Text("You can find the pairing code in Speak's settings on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pair with \(macName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair", action: onPair)
                        .disabled(pairingCode.count < 6)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack {
        SendToMacView()
    }
}
#endif
