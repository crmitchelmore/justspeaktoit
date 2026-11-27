import Foundation

/// Validated endpoint guaranteed safe to probe or call with studio requests.
public struct ValidatedVoiceStudioEndpoint: Equatable, Sendable {
    public let url: URL
    public let scheme: String
    public let host: String
    public let port: Int?
    public let isLoopback: Bool
    public let sanitizedURLString: String

    /// Resolves a relative endpoint path (such as `"profiles"` or `"v1/audio/speech"`) against the base URL.
    public func endpointURL(path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return url
        }
        return trimmed.split(separator: "/").reduce(url) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    /// Resolves a studio-returned `audio_url` only if it stays on the exact same scheme, host, and effective port.
    public func resolveSameOriginAudioURL(_ raw: String, kind: VoiceStudioKind) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceStudioError.invalidResponse(kind: kind, detail: "Empty audio URL in studio response.")
        }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw VoiceStudioError.invalidResponse(kind: kind, detail: "Invalid control character in audio URL.")
        }

        let resolved: URL
        if let candidate = URL(string: trimmed), candidate.scheme != nil {
            resolved = candidate
        } else if let relative = URL(string: trimmed, relativeTo: url)?.absoluteURL {
            resolved = relative
        } else {
            throw VoiceStudioError.invalidResponse(kind: kind, detail: "Malformed audio URL returned by studio.")
        }

        guard let resolvedComponents = URLComponents(url: resolved, resolvingAgainstBaseURL: true),
              resolvedComponents.user == nil,
              resolvedComponents.password == nil,
              let targetScheme = resolvedComponents.scheme?.lowercased(),
              let rawTargetHost = resolvedComponents.host,
              let targetHost = VoiceStudioEndpointPolicy.normalizedHost(rawTargetHost)
        else {
            throw VoiceStudioError.crossOriginAudioURLDisallowed(origin: "invalid-url")
        }

        let sourceEffectivePort = effectivePort(scheme: scheme, port: port)
        let targetEffectivePort = effectivePort(scheme: targetScheme, port: resolvedComponents.port)
        guard targetScheme == scheme, targetHost == host, targetEffectivePort == sourceEffectivePort else {
            throw VoiceStudioError.crossOriginAudioURLDisallowed(origin: "\(targetScheme)://\(targetHost)")
        }
        return resolved
    }

    private func effectivePort(scheme: String, port: Int?) -> Int {
        if let port { return port }
        return scheme == "https" ? 443 : 80
    }
}

/// Security policy enforcing loopback-only cleartext HTTP and authenticated HTTPS for remote studio hosts.
public enum VoiceStudioEndpointPolicy {
    /// Validates base URL syntax and network policy for configuration or request execution.
    public static func validate(
        baseURLString: String,
        apiKey: String?,
        requireAPIKeyForRemote: Bool = true
    ) throws -> ValidatedVoiceStudioEndpoint {
        let parsed = try parseValidatedComponents(baseURLString)
        let loopback = isLoopbackHost(parsed.host)
        if parsed.scheme == "http", !loopback {
            throw VoiceStudioError.cleartextNonLoopbackDisallowed(host: parsed.host)
        }
        if !loopback, requireAPIKeyForRemote {
            let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmedKey.isEmpty {
                throw VoiceStudioError.remoteHTTPSRequiresAPIKey(host: parsed.host)
            }
        }
        return try makeValidatedEndpoint(
            parsed: parsed,
            isLoopback: loopback
        )
    }

    private struct ParsedEndpointComponents {
        let components: URLComponents
        let scheme: String
        let host: String
    }

    private static func parseValidatedComponents(
        _ baseURLString: String
    ) throws -> ParsedEndpointComponents {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceStudioError.invalidURL(detail: "Server URL cannot be empty.")
        }
        let hasDisallowedChars = trimmed.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0)
        }
        guard !hasDisallowedChars else {
            throw VoiceStudioError.invalidURL(detail: "Server URL contains whitespace or control characters.")
        }
        guard let components = URLComponents(string: trimmed) else {
            throw VoiceStudioError.invalidURL(detail: "Unable to parse URL.")
        }
        if components.user != nil || components.password != nil || authorityContainsAtSign(trimmed) {
            throw VoiceStudioError.credentialsInURLDisallowed
        }
        guard let rawScheme = components.scheme?.lowercased(), rawScheme == "http" || rawScheme == "https" else {
            throw VoiceStudioError.invalidURL(detail: "Only http:// (loopback only) and https:// URLs are allowed.")
        }
        guard components.query == nil, components.fragment == nil else {
            throw VoiceStudioError.invalidURL(detail: "Server URL must not contain query parameters or fragments.")
        }
        guard let rawHost = components.host, !rawHost.isEmpty, let host = normalizedHost(rawHost) else {
            throw VoiceStudioError.invalidURL(detail: "Server URL must include a valid host.")
        }
        return ParsedEndpointComponents(components: components, scheme: rawScheme, host: host)
    }

    private static func makeValidatedEndpoint(
        parsed: ParsedEndpointComponents,
        isLoopback: Bool
    ) throws -> ValidatedVoiceStudioEndpoint {
        var normalizedComponents = URLComponents()
        normalizedComponents.scheme = parsed.scheme
        normalizedComponents.percentEncodedHost = parsed.components.percentEncodedHost ?? parsed.components.host
        normalizedComponents.port = parsed.components.port
        normalizedComponents.path = normalizedBasePath(parsed.components.path)

        guard let url = normalizedComponents.url,
              let sanitizedString = normalizedComponents.string
        else {
            throw VoiceStudioError.invalidURL(detail: "Unable to normalize server URL.")
        }

        return ValidatedVoiceStudioEndpoint(
            url: url,
            scheme: parsed.scheme,
            host: parsed.host,
            port: parsed.components.port,
            isLoopback: isLoopback,
            sanitizedURLString: sanitizedString
        )
    }

    /// Checks whether a host refers strictly to loopback (`localhost`, canonical `127.x.y.z`, or IPv6 `::1`).
    public static func isLoopbackHost(_ rawHost: String) -> Bool {
        guard let host = normalizedHost(rawHost) else { return false }
        if host == "localhost" {
            return true
        }
        if isExplicitIPv4Loopback(host) {
            return true
        }
        return isCanonicalIPv6Loopback(host)
    }

    /// Normalizes brackets and ASCII casing while rejecting zone identifiers and malformed host strings.
    static func normalizedHost(_ rawHost: String) -> String? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        if host.hasPrefix("[") || host.hasSuffix("]") {
            guard host.hasPrefix("[") && host.hasSuffix("]") else { return nil }
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty, !host.contains("%"), !host.contains("@") else { return nil }
        return host
    }

    private static func authorityContainsAtSign(_ urlString: String) -> Bool {
        guard let schemeRange = urlString.range(of: "://") else { return false }
        let afterScheme = urlString[schemeRange.upperBound...]
        let authorityEnd = afterScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? afterScheme.endIndex
        return afterScheme[..<authorityEnd].contains("@")
    }

    private static func normalizedBasePath(_ path: String) -> String {
        var result = path
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    private static func isExplicitIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            // Reject empty, signs, leading zeros (octal ambiguity), and non-ASCII digits.
            guard !part.isEmpty,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  part.count == 1 || part.first != "0",
                  let value = UInt8(part)
            else {
                return false
            }
            octets.append(value)
        }
        return octets.first == 127
    }

    private static func isCanonicalIPv6Loopback(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        let pieces = host.components(separatedBy: "::")
        guard pieces.count <= 2 else { return false }

        let leftGroups: [UInt16]
        let rightGroups: [UInt16]

        if pieces.count == 1 {
            guard let parsed = parseIPv6Groups(pieces[0]), parsed.count == 8 else { return false }
            leftGroups = parsed
            rightGroups = []
        } else {
            let leftStr = pieces[0]
            let rightStr = pieces[1]
            let parsedLeft = leftStr.isEmpty ? [] : parseIPv6Groups(leftStr)
            let parsedRight = rightStr.isEmpty ? [] : parseIPv6Groups(rightStr)
            guard let unwrappedLeft = parsedLeft, let unwrappedRight = parsedRight else { return false }
            guard unwrappedLeft.count + unwrappedRight.count < 8 else { return false }
            leftGroups = unwrappedLeft
            rightGroups = unwrappedRight
        }

        let zeroCount = 8 - leftGroups.count - rightGroups.count
        let groups = leftGroups + Array(repeating: UInt16(0), count: zeroCount) + rightGroups
        guard groups.count == 8 else { return false }
        return groups.dropLast().allSatisfy { $0 == 0 } && groups.last == 1
    }

    private static func parseIPv6Groups(_ segmentString: String) -> [UInt16]? {
        let parts = segmentString.split(separator: ":", omittingEmptySubsequences: false)
        var groups: [UInt16] = []
        groups.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.count <= 4,
                  let value = UInt16(part, radix: 16)
            else {
                return nil
            }
            groups.append(value)
        }
        return groups
    }
}
