import Foundation

// MARK: - Rev.ai

/// Rev.ai's account endpoint reports the transcription seconds left on the
/// account: `GET /speechtotext/v1/account`.
/// https://docs.rev.ai/api/asynchronous/reference
public struct RevAIBalanceClient: ProviderBalanceSource {
    public let accountID = "revai"
    private let session: URLSession
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.rev.ai")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now
    }

    public func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        let data: Data
        switch await ProviderBalanceTransport.get(
            baseURL.appendingPathComponent("speechtotext/v1/account"),
            headers: ["Authorization": "Bearer \(apiKey)"],
            session: session
        ) {
        case .value(let body): data = body
        case .failed(let state): return snapshot(state)
        }

        switch ProviderBalanceTransport.decode(RevAIAccountResponse.self, from: data) {
        case .failed(let state):
            return snapshot(state)
        case .value(let account):
            guard let seconds = account.balanceSeconds else {
                return snapshot(.unknown(reason: "Rev.ai did not report a remaining balance."))
            }
            // Rev.ai meters seconds of audio, not money, and publishes no
            // ceiling — so the total stays unknown rather than unlimited.
            return snapshot(.allowance(remaining: seconds, total: nil, unit: .seconds))
        }
    }

    private func snapshot(_ state: ProviderBalanceState) -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            accountID: accountID,
            providerDisplayName: "Rev.ai",
            state: state,
            refreshedAt: now()
        )
    }
}

// MARK: - Wire format

private struct RevAIAccountResponse: Decodable {
    let balanceSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case balanceSeconds = "balance_seconds"
    }
}
