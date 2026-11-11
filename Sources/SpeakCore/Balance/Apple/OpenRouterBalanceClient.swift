import Foundation

// MARK: - OpenRouter

/// OpenRouter publishes a prepaid credit wallet: `GET /api/v1/credits`.
/// https://openrouter.ai/docs/api/api-reference/credits/get-credits
public struct OpenRouterBalanceClient: ProviderBalanceSource {
    public let accountID = "openrouter"
    private let session: URLSession
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://openrouter.ai")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now
    }

    public func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        let data: Data
        switch await ProviderBalanceTransport.get(
            baseURL.appendingPathComponent("api/v1/credits"),
            headers: ["Authorization": "Bearer \(apiKey)"],
            session: session
        ) {
        case .value(let body): data = body
        case .failed(let state): return snapshot(state)
        }

        switch ProviderBalanceTransport.decode(OpenRouterCreditsResponse.self, from: data) {
        case .failed(let state):
            return snapshot(state)
        case .value(let credits):
            guard let purchased = credits.data.totalCredits, let used = credits.data.totalUsage else {
                return snapshot(.unknown(reason: "OpenRouter did not report both purchased and used credits."))
            }
            let remainder = purchased - used
            // Usage above purchased credit is an overdrawn or postpaid
            // account, not a negative wallet: reporting it as `.cash` would
            // mark it spendable and format it as credit.
            guard remainder >= 0 else {
                return snapshot(.usage(
                    spent: ProviderBalanceMoney(amount: Decimal(used), currencyCode: "USD"),
                    quantity: nil,
                    unit: nil,
                    note: "OpenRouter reports more usage than purchased credit on this account, "
                        + "so there is no spendable balance to show."
                ))
            }
            return snapshot(
                .cash(ProviderBalanceMoney(amount: Decimal(remainder), currencyCode: "USD"))
            )
        }
    }

    private func snapshot(_ state: ProviderBalanceState) -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            accountID: accountID,
            providerDisplayName: "OpenRouter",
            state: state,
            refreshedAt: now()
        )
    }
}

// MARK: - Wire format

private struct OpenRouterCreditsPayload: Decodable {
    let totalCredits: Double?
    let totalUsage: Double?

    enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

private struct OpenRouterCreditsResponse: Decodable {
    let data: OpenRouterCreditsPayload
}
