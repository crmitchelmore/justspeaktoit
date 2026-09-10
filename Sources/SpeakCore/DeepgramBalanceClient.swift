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

        guard let projectID = projects.projects.first?.projectID else {
            return snapshot(.unknown(reason: "This Deepgram key has no projects to bill."))
        }

        let balancesData: Data
        switch await ProviderBalanceTransport.get(
            baseURL.appendingPathComponent("v1/projects/\(projectID)/balances"),
            headers: headers,
            session: session
        ) {
        case .value(let data): balancesData = data
        case .failed(let state): return snapshot(state)
        }

        switch ProviderBalanceTransport.decode(DeepgramBalancesResponse.self, from: balancesData) {
        case .failed(let state):
            return snapshot(state)
        case .value(let response):
            return snapshot(state(from: response))
        }
    }

    private func state(from response: DeepgramBalancesResponse) -> ProviderBalanceState {
        guard let first = response.balances.first else {
            // No balance record is not zero credit and not unlimited credit:
            // Deepgram simply told us nothing about a wallet here.
            return .unknown(reason: "Deepgram reported no balance for this project.")
        }
        let units = (first.units ?? "").lowercased()
        // Only sum records that share a unit; mixing dollars with anything else
        // would invent a figure the provider never published.
        let total = response.balances
            .filter { ($0.units ?? "").lowercased() == units }
            .reduce(0.0) { $0 + $1.amount }

        if units == "usd" {
            return .cash(ProviderBalanceMoney(amount: Decimal(total), currencyCode: "USD"))
        }
        if units.isEmpty {
            return .unknown(reason: "Deepgram did not say what this balance is measured in.")
        }
        return .allowance(remaining: total, total: nil, unit: .other(units))
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

private struct DeepgramBalanceEntry: Decodable {
    let amount: Double
    let units: String?
}

private struct DeepgramBalancesResponse: Decodable {
    let balances: [DeepgramBalanceEntry]
}
