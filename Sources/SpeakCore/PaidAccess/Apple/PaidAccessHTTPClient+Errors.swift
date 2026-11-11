import Foundation

extension PaidAccessHTTPClient {
    /// URL-safe, matching the Worker's accepted correlation-id shape.
    static func newCorrelationID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Maps the Worker's error vocabulary onto ``PaidAccessError``.
    ///
    /// Response bodies are parsed for the machine-readable `code` only; the
    /// human message is not echoed because upstream messages can contain
    /// request content.
    static func error(
        forStatus statusCode: Int, body: Data,
        submittedOperation: String? = nil, correlationID: String? = nil
    ) -> PaidAccessError {
        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error.code
        let unknown = PaidAccessError.operationOutcome(
            .unknown, idempotencyKey: submittedOperation ?? "", correlationID: correlationID
        )
        if let retained = Self.settlementError(
            for: code, submittedOperation: submittedOperation, correlationID: correlationID, unknown: unknown
        ) {
            return retained
        }
        switch code {
        case "entitlement_required": return .entitlementRequired
        case "quota_exceeded": return .quotaExceeded
        case "too_many_sessions": return .tooManySessions
        case "paid_routing_disabled": return .paidRoutingDisabled
        case "unauthorized": return submittedOperation == nil ? .notSignedIn : unknown
        case "already_processed": return .alreadyProcessed
        case "forbidden":
            return .billingChannelUnavailable(
                "This build cannot use that payment method."
            )
        default:
            if submittedOperation != nil { return unknown }
            return statusCode == 401 ? .notSignedIn : .serviceUnavailable(statusCode: statusCode)
        }
    }

    private static func settlementError(
        for code: String?, submittedOperation: String?, correlationID: String?, unknown: PaidAccessError
    ) -> PaidAccessError? {
        switch code {
        case "request_in_progress":
            return .operationOutcome(
                .inProgress, idempotencyKey: submittedOperation ?? "", correlationID: correlationID
            )
        case "settlement_pending":
            return .operationOutcome(
                .settlementPending, idempotencyKey: submittedOperation ?? "", correlationID: correlationID
            )
        case "outcome_unknown": return unknown
        case "request_not_started": return .requestNotStarted
        default: return nil
        }
    }

    private struct ErrorPayload: Decodable {
        let code: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorPayload
    }
}
