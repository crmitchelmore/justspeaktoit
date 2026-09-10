import Foundation

// MARK: - ElevenLabs

/// ElevenLabs meters characters against a subscription allowance:
/// `GET /v1/user/subscription`.
/// https://elevenlabs.io/docs/api-reference/user/subscription/get
public struct ElevenLabsBalanceClient: ProviderBalanceSource {
    public let accountID = "elevenlabs"
    private let session: URLSession
    private let baseURL: URL
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.elevenlabs.io")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.now = now
    }

    public func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        let data: Data
        switch await ProviderBalanceTransport.get(
            baseURL.appendingPathComponent("v1/user/subscription"),
            headers: ["xi-api-key": apiKey],
            session: session
        ) {
        case .value(let body): data = body
        case .failed(let state): return snapshot(state, resetsAt: nil, planName: nil)
        }

        switch ProviderBalanceTransport.decode(ElevenLabsSubscriptionResponse.self, from: data) {
        case .failed(let state):
            return snapshot(state, resetsAt: nil, planName: nil)
        case .value(let subscription):
            let resetsAt = subscription.nextCharacterCountResetUnix.map(Date.init(timeIntervalSince1970:))
            return snapshot(state(from: subscription), resetsAt: resetsAt, planName: subscription.tier)
        }
    }

    private func state(from subscription: ElevenLabsSubscriptionResponse) -> ProviderBalanceState {
        // A subscription without a character limit tells us nothing about how
        // much is left. It is emphatically not an unlimited allowance.
        guard let limit = subscription.characterLimit else {
            return .unknown(reason: "ElevenLabs did not report a character limit for this plan.")
        }
        // An omitted usage counter is not zero usage. Substituting zero would
        // show the whole plan as untouched on a partial response, which is the
        // one number a user must never be shown as fact.
        guard let used = subscription.characterCount else {
            return .unknown(
                reason: "ElevenLabs did not report how many characters this plan has used."
            )
        }
        let remaining = max(0, limit - used)
        if (subscription.tier ?? "").lowercased().contains("free") {
            return .freeQuota(remaining: remaining, total: limit, unit: .characters)
        }
        return .allowance(remaining: remaining, total: limit, unit: .characters)
    }

    private func snapshot(
        _ state: ProviderBalanceState,
        resetsAt: Date?,
        planName: String?
    ) -> ProviderBalanceSnapshot {
        ProviderBalanceSnapshot(
            accountID: accountID,
            providerDisplayName: "ElevenLabs",
            state: state,
            refreshedAt: now(),
            resetsAt: resetsAt,
            planName: planName
        )
    }
}

// MARK: - Wire format

private struct ElevenLabsSubscriptionResponse: Decodable {
    let tier: String?
    let characterCount: Double?
    let characterLimit: Double?
    let nextCharacterCountResetUnix: Double?

    enum CodingKeys: String, CodingKey {
        case tier
        case characterCount = "character_count"
        case characterLimit = "character_limit"
        case nextCharacterCountResetUnix = "next_character_count_reset_unix"
    }
}
