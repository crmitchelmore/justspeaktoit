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
options.sendDefaultPii = false
```

With transcript content removed from logs and default PII collection disabled,
ordinary diagnostic events should not contain user speech. New Sentry context and
breadcrumbs must still be reviewed so free-form user content cannot be added by
another path.

### Windows and Linux crash reports

The desktop apps send Sentry envelopes without the SDK
(`Sources/SpeakDesktop/Telemetry/DesktopTelemetryTransport.swift`), only after the
user turns on **Send crash reports and diagnostics** and only from release builds.
An event holds the error type and a message passed through
`DesktopTelemetryScrubber`, which replaces quoted text (where transcripts and
prompts appear), URL paths and queries, bearer tokens, `key=value` secrets,
provider keys and other long tokens, e-mail addresses, UUIDs, home folders
(`C:\Users\<name>`, `/home/<name>`, `/Users/<name>`) and network shares, then caps
the message at 300 characters. Events carry no user, server name, request,
breadcrumbs, stack locals or analytics install ID. `DesktopTelemetryScrubberTests`
covers each rule.

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
