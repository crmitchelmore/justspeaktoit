import Combine
import Foundation
import Network

/// Finds Macs running the Send to Mac receiver on the local network.
@MainActor
public final class MacDiscovery: ObservableObject {
    public struct DiscoveredMac: Identifiable, Equatable {
        public let name: String
        public let endpoint: NWEndpoint

        public var id: String { self.name }

        public init(name: String, endpoint: NWEndpoint) {
            self.name = name
            self.endpoint = endpoint
        }
    }

    @Published public private(set) var discoveredMacs: [DiscoveredMac] = []
    @Published public private(set) var isSearching = false
    /// Why browsing stopped, such as Local Network access being denied.
    @Published public private(set) var failureMessage: String?

    private static let logger = SpeakLogger.logger(category: "SendToMac")
    private var browser: NWBrowser?

    public init() {}

    public func startSearching() {
        guard self.browser == nil else { return }
        self.isSearching = true
        self.failureMessage = nil
        self.discoveredMacs = []

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: SpeakTransportServiceType, domain: "local."), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stopSearching() {
        self.browser?.cancel()
        self.browser = nil
        self.isSearching = false
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            Self.logger.error("Send to Mac discovery failed: \(error.localizedDescription, privacy: .public)")
            self.failureMessage = error.localizedDescription
            self.stopSearching()
        case .waiting(let error):
            // Waiting is how a denied Local Network permission shows up.
            self.failureMessage = error.localizedDescription
        case .ready:
            self.failureMessage = nil
        default:
            break
        }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var macs: [String: DiscoveredMac] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            macs[name] = DiscoveredMac(name: name, endpoint: result.endpoint)
        }
        self.discoveredMacs = macs.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
