import Foundation

/// Redacts sensitive header values to prevent exposure in debug UI, logs, or screenshots
public enum SensitiveHeaderRedactor {
    /// Headers that may contain sensitive authentication or API key information
    private static let sensitiveHeaderKeys: Set<String> = [
        "authorization",
        "api-key",
        "x-api-key",
        "token",
        "x-auth-token",
        "bearer",
        "x-access-token",
        "openai-api-key",
        "deepgram-api-key",
        "anthropic-api-key"
    ]
    
    /// Redacts sensitive headers in a dictionary by masking values
    /// - Parameter headers: Dictionary of HTTP headers
    /// - Returns: Dictionary with sensitive values redacted
    public static func redactSensitiveHeaders(_ headers: [String: String]) -> [String: String] {
        headers.mapValues { value in
            // Check if this is likely a sensitive value based on common patterns
            if isSensitiveValue(value) {
                return redactValue(value)
            }
            return value
        }
    }
    
    /// Determines if a header key is sensitive
    /// - Parameter key: Header name
    /// - Returns: True if the header is known to contain sensitive data
    public static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveHeaderKeys.contains(normalized)
    }
    
    /// Checks if a value appears to be sensitive (e.g., API key, token)
    /// - Parameter value: Header value to check
    /// - Returns: True if the value matches common sensitive patterns
    private static func isSensitiveValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        
        // Common API key patterns
        let patterns = [
            "^sk-[A-Za-z0-9]{20,}$",           // OpenAI style: sk-...
            "^Bearer .+$",                       // Bearer tokens
            "^[A-Za-z0-9]{32,}$",               // Long alphanumeric strings (likely keys)
            "^[A-Za-z0-9_-]{40,}$",             // JWT-style tokens
        ]
        
        for pattern in patterns {
            if trimmed.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        
        return false
    }
    
    /// Redacts a sensitive value by showing only first 3 and last 4 characters
    /// - Parameter value: The sensitive value to redact
    /// - Returns: Redacted string in format "abc...xyz1" or "[REDACTED]" if too short
    public static func redactValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        
        // Handle Bearer tokens specially
        if trimmed.hasPrefix("Bearer ") {
            let token = String(trimmed.dropFirst(7))
            return "Bearer \(redactValue(token))"
        }
        
        // For very short values, just fully redact
        guard trimmed.count >= 10 else {
            return "[REDACTED]"
        }
        
        // Show first 3 and last 4 characters with ellipsis in between
        let prefix = String(trimmed.prefix(3))
        let suffix = String(trimmed.suffix(4))
        return "\(prefix)...\(suffix)"
    }
}
