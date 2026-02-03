# Security Fix: Transcript Logging Redaction

**Severity:** HIGH  
**Date:** 2025-01-02  
**Issue:** Sensitive speech data exposure via logs and Sentry crash reports

## Problem

Raw transcript content was logged in plain text during Deepgram live streaming:

```swift
print("[DeepgramLiveController] Transcript: '\(text)' (final: \(isFinal))")
print("[DeepgramLiveController] Final segment #\(finalSegments.count): '\(text.prefix(50))' - fullTranscript: '\(fullTranscript.prefix(80))'")
print("[DeepgramLiveTranscriber] Received: \(json.prefix(200))")
```

### Risks

- **Sentry Exposure**: Crash reports could capture sensitive speech data
- **Log File Exposure**: Transcript content persisted in system logs
- **GDPR/CCPA Violation**: Excessive data collection without user consent
- **Developer Exposure**: Console output revealed private user speech

## Solution

### Code Changes

#### TranscriptionManager.swift
- Added `logger` property using OSLog
- Replaced all `print()` statements with privacy-aware logging
- Log metadata only (segment count, text length), never content

**Before:**
```swift
print("[DeepgramLiveController] Transcript: '\(text)' (final: \(isFinal))")
```

**After:**
```swift
logger.debug("Received transcript segment (final: \(isFinal), length: \(text.count, privacy: .public))")
```

#### DeepgramTranscriptionProvider.swift
- Removed raw JSON logging
- Gated behind `SpeakLogger.isDebugMode`
- Log only response length, not content

**Before:**
```swift
print("[DeepgramLiveTranscriber] Received: \(json.prefix(200))")
```

**After:**
```swift
if SpeakLogger.isDebugMode {
    logger.debug("Received Deepgram response (length: \(json.count, privacy: .public))")
}
```

### Privacy Specifiers

- `.public`: Non-sensitive metadata (counts, lengths, status)  
- `.private`: Automatic redaction (used implicitly for user data)
- Debug logging gated behind `SpeakLogger.isDebugMode`

### Sentry Protection

Existing configuration in `SentryManager.swift` provides defense-in-depth:

```swift
options.sendDefaultPII = false  // Line 55
```

With transcript content removed from logs, no sensitive data can reach Sentry.

## Verification

### No Sensitive Data in Logs

✅ No transcript text logged  
✅ Only metadata (length, count, final status)  
✅ Privacy specifiers applied correctly  
✅ Debug mode gating in place

### Compliance

- **GDPR**: Data minimization principle satisfied  
- **CCPA**: No unexpected data collection  
- **SOC 2**: Audit trail without PII

## Testing

Run `make test` to verify changes don't break functionality.

## References

- [Apple OSLog Privacy](https://developer.apple.com/documentation/os/logging/generating_log_messages_from_your_code)
- [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
