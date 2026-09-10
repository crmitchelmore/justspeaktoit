import Foundation

/// Reads one account's balance from its provider.
///
/// Deliberately non-throwing: a settings screen must render whether or not a
/// billing endpoint answers, so every failure — auth, quota, cancellation, a
/// malformed body — comes back as an `unknown` state carrying the reason.
public protocol ProviderBalanceSource: Sendable {
    var accountID: String { get }
    func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot
}

/// The outcome of one step of a balance request: a value, or the state that
/// explains why there is none. Failures are states rather than errors because
/// the settings screen has to render them, not catch them.
enum ProviderBalanceFetch<Value> {
    case value(Value)
    case failed(ProviderBalanceState)
}

/// Shared plumbing for the balance transports: one authenticated GET, decoded,
/// with every failure mode mapped onto a state instead of an error.
enum ProviderBalanceTransport {
    static func get(
        _ url: URL,
        headers: [String: String],
        session: URLSession
    ) async -> ProviderBalanceFetch<Data> {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(.unknown(reason: "The billing endpoint returned a non-HTTP response."))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failed(.unknown(reason: message(forStatus: http.statusCode)))
            }
            return .value(data)
        } catch is CancellationError {
            return .failed(.unknown(reason: "The balance check was cancelled."))
        } catch let error as URLError where error.code == .cancelled {
            return .failed(.unknown(reason: "The balance check was cancelled."))
        } catch {
            return .failed(.unknown(reason: "Could not reach the billing endpoint: \(error.localizedDescription)"))
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> ProviderBalanceFetch<T> {
        do {
            return .value(try JSONDecoder().decode(type, from: data))
        } catch {
            return .failed(.unknown(reason: "The billing endpoint returned an unexpected response."))
        }
    }

    /// Distinguishes the failures a user can act on. A rejected key and an
    /// exhausted quota are different problems, and neither means "no credit".
    static func message(forStatus status: Int) -> String {
        switch status {
        case 401, 403:
            return "The saved key is not authorised to read billing (HTTP \(status))."
        case 404:
            return "The provider has no billing record for this key (HTTP 404)."
        case 429:
            return "The provider rate-limited the balance check (HTTP 429). Try again shortly."
        default:
            return "The billing endpoint replied HTTP \(status)."
        }
    }
}
