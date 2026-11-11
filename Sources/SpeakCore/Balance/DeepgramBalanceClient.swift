import Foundation

// MARK: - Deepgram

/// Deepgram's project balances: `GET /v1/projects`, then
/// `GET /v1/projects/{id}/balances`.
/// https://developers.deepgram.com/reference/manage/billing/get
public struct DeepgramBalanceClient: ProviderBalanceSource {
    public let accountID = "deepgram"
    private let session: URLSession
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.deepgram.com")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now
    }

    /// Projects one key may bill before the figure stops being useful.
    ///
    /// Each one costs a request, so the walk is bounded; a key with more than
    /// this many billable projects is reported as unknown rather than shown a
    /// number that covers only some of them.
    static let maximumProjects = 10

    public func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        let headers = ["Authorization": "Token \(apiKey)"]

        let projectsData: Data
        switch await ProviderBalanceTransport.get(
            baseURL.appendingPathComponent("v1/projects"),
            headers: headers,
            session: session
        ) {
        case .value(let data): projectsData = data
        case .failed(let state): return snapshot(state)
        }

        let projects: DeepgramProjectsResponse
        switch ProviderBalanceTransport.decode(DeepgramProjectsResponse.self, from: projectsData) {
        case .value(let decoded): projects = decoded
        case .failed(let state): return snapshot(state)
        }

        let projectIDs = projects.projects.map(\.projectID)
        guard !projectIDs.isEmpty else {
            return snapshot(.unknown(reason: "This Deepgram key has no projects to bill."))
        }
        // A key can reach several projects, and response order is not a
        // meaningful choice between their wallets: either every billable
        // project is counted, or no figure is claimed.
        guard projectIDs.count <= Self.maximumProjects else {
            return snapshot(.unknown(
                reason: "This Deepgram key bills \(projectIDs.count) projects, more than Speak "
                    + "totals. Check the balance in the Deepgram console."
            ))
        }

        var entries: [DeepgramBalanceEntry] = []
        for projectID in projectIDs {
            switch await balances(forProject: projectID, headers: headers) {
            case .value(let projectEntries): entries += projectEntries
            // One unreadable project makes the total wrong, so nothing is
            // claimed rather than a partial sum presented as the whole.
            case .failed(let state): return snapshot(state)
            }
        }
        return snapshot(state(from: entries, projectCount: projectIDs.count))
    }

    private func balances(
        forProject projectID: String,
        headers: [String: String]
    ) async -> ProviderBalanceFetch<[DeepgramBalanceEntry]> {
        let data: Data
        switch await ProviderBalanceTransport.get(
            baseURL.appendingPathComponent("v1/projects/\(projectID)/balances"),
            headers: headers,
            session: session
        ) {
        case .value(let body): data = body
        case .failed(let state): return .failed(state)
        }

        switch ProviderBalanceTransport.decode(DeepgramBalancesResponse.self, from: data) {
        case .value(let response): return .value(response.balances)
        case .failed(let state): return .failed(state)
        }
    }

    private func state(
        from entries: [DeepgramBalanceEntry],
        projectCount: Int
    ) -> ProviderBalanceState {
        guard !entries.isEmpty else {
            // No balance record is not zero credit and not unlimited credit:
            // Deepgram simply told us nothing about a wallet here.
            return .unknown(
                reason: projectCount == 1
                    ? "Deepgram reported no balance for this project."
                    : "Deepgram reported no balance for any of this key's projects."
            )
        }
        let units = Set(entries.map { ($0.units ?? "").lowercased() })
        // Mixing dollars with anything else would invent a figure the provider
        // never published.
        guard units.count == 1, let unit = units.first else {
            return .unknown(
                reason: "Deepgram reported balances in more than one unit for this key."
            )
        }
        let total = entries.reduce(0.0) { $0 + $1.amount }

        if unit == "usd" {
            return .cash(ProviderBalanceMoney(amount: Decimal(total), currencyCode: "USD"))
        }
        if unit.isEmpty {
            return .unknown(reason: "Deepgram did not say what this balance is measured in.")
        }
        return .allowance(remaining: total, total: nil, unit: .other(unit))
    }

    private func snapshot(_ state: ProviderBalanceState) -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            accountID: accountID,
            providerDisplayName: "Deepgram",
            state: state,
            refreshedAt: now()
        )
    }
}

// MARK: - Wire format

private struct DeepgramProject: Decodable {
    let projectID: String

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
    }
}

private struct DeepgramProjectsResponse: Decodable {
    let projects: [DeepgramProject]
}

struct DeepgramBalanceEntry: Decodable {
    let amount: Double
    let units: String?
}

private struct DeepgramBalancesResponse: Decodable {
    let balances: [DeepgramBalanceEntry]
}
