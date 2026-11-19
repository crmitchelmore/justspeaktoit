import Foundation

// MARK: - Query

/// Reading capture parameters out of a link's query.
///
/// A URL query is a list, not a dictionary: `?lang=en_US&lang=klingon` is
/// perfectly well formed and carries two values. Taking the first silently
/// discards the second, which is the one case this vocabulary must never
/// produce — a caller that supplied an unknown or conflicting value would be
/// recorded under the *other* one and never told. So a repeat is a refusal,
/// unless every occurrence says the same thing, which asks for nothing
/// ambiguous.
public enum CaptureLinkQuery {
    /// The one value supplied for `name`, matched case-insensitively.
    ///
    /// - Returns: `nil` when the parameter is absent.
    /// - Throws: `CaptureLinkFailure.repeatedParameter` when it was supplied
    ///   more than once with values that do not agree.
    public static func singleValue(
        _ name: String,
        in queryItems: [URLQueryItem]
    ) throws -> String? {
        let matches = queryItems.filter { $0.name.lowercased() == name.lowercased() }
        guard let first = matches.first else { return nil }
        guard matches.allSatisfy({ $0.value == first.value }) else {
            throw CaptureLinkFailure.repeatedParameter
        }
        return first.value
    }

    /// Whether `name` appears at all, however many times and whatever its value.
    public static func isPresent(_ name: String, in queryItems: [URLQueryItem]) -> Bool {
        queryItems.contains { $0.name.lowercased() == name.lowercased() }
    }

    /// Whether `name` appears more than once with values that do not agree.
    public static func hasConflictingRepeat(
        _ name: String,
        in queryItems: [URLQueryItem]
    ) -> Bool {
        do {
            _ = try singleValue(name, in: queryItems)
            return false
        } catch {
            return true
        }
    }
}
