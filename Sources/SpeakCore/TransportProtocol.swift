import Foundation

// MARK: - Transport Protocol

/// Service type for Bonjour discovery
public let SpeakTransportServiceType = "_speaktransport._tcp"

/// Protocol version for compatibility checking
public let SpeakTransportProtocolVersion = 1

// MARK: - Message Types

/// Messages exchanged between iOS and macOS over WebSocket.
public enum TransportMessage: Codable {
    case hello(HelloMessage)
    case authenticate(AuthenticateMessage)
    case authResult(AuthResultMessage)
    case sessionStart(SessionStartMessage)
    case sessionEnd(SessionEndMessage)
    case transcriptChunk(TranscriptChunkMessage)
    case ack(AckMessage)
    case error(ErrorMessage)
    case ping
    case pong
    /// Local automation (CLI / MCP) command, carried over the same envelope so
    /// there is one message contract for every non-UI client.
    case automationRequest(AutomationRequest)
    case automationResponse(AutomationResponse)

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum MessageType: String, Codable {
        case hello, authenticate, authResult
        case sessionStart, sessionEnd
        case transcriptChunk, ack, error
        case ping, pong
        case automationRequest, automationResponse
    }

    // Exhaustive Codable mapping: one case per wire type, so complexity tracks
    // the message count rather than any real branching logic.
    // swiftlint:disable:next cyclomatic_complexity
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)

        switch type {
        case .hello:
            self = .hello(try container.decode(HelloMessage.self, forKey: .payload))
        case .authenticate:
            self = .authenticate(try container.decode(AuthenticateMessage.self, forKey: .payload))
        case .authResult:
            self = .authResult(try container.decode(AuthResultMessage.self, forKey: .payload))
        case .sessionStart:
            self = .sessionStart(try container.decode(SessionStartMessage.self, forKey: .payload))
        case .sessionEnd:
            self = .sessionEnd(try container.decode(SessionEndMessage.self, forKey: .payload))
        case .transcriptChunk:
            self = .transcriptChunk(try container.decode(TranscriptChunkMessage.self, forKey: .payload))
        case .ack:
            self = .ack(try container.decode(AckMessage.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ErrorMessage.self, forKey: .payload))
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        case .automationRequest:
            self = .automationRequest(try container.decode(AutomationRequest.self, forKey: .payload))
        case .automationResponse:
            self = .automationResponse(try container.decode(AutomationResponse.self, forKey: .payload))
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hello(let msg):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .authenticate(let msg):
            try container.encode(MessageType.authenticate, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .authResult(let msg):
            try container.encode(MessageType.authResult, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .sessionStart(let msg):
            try container.encode(MessageType.sessionStart, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .sessionEnd(let msg):
            try container.encode(MessageType.sessionEnd, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .transcriptChunk(let msg):
            try container.encode(MessageType.transcriptChunk, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .ack(let msg):
            try container.encode(MessageType.ack, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .error(let msg):
            try container.encode(MessageType.error, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .ping:
            try container.encode(MessageType.ping, forKey: .type)
        case .pong:
            try container.encode(MessageType.pong, forKey: .type)
        case .automationRequest(let msg):
            try container.encode(MessageType.automationRequest, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .automationResponse(let msg):
            try container.encode(MessageType.automationResponse, forKey: .type)
            try container.encode(msg, forKey: .payload)
        }
    }
}

// MARK: - Message Payloads

public struct HelloMessage: Codable {
    public var protocolVersion: Int
    public var deviceName: String
    public var deviceId: String
    /// Optional feature flags this endpoint supports beyond the base protocol.
    ///
    /// Optional (and additive) on purpose: older builds omit the key entirely and
    /// still decode, so advertising a capability never breaks an existing client.
    public var capabilities: [TransportCapability]?

    public init(
        protocolVersion: Int = SpeakTransportProtocolVersion,
        deviceName: String,
        deviceId: String,
        capabilities: [TransportCapability]? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.capabilities = capabilities
    }

    public func supports(_ capability: TransportCapability) -> Bool {
        self.capabilities?.contains(capability) ?? false
    }

    /// Whether this hello's protocol version is compatible with the running build.
    ///
    /// Policy: exact match. Both endpoints ship from this repository, so there is no
    /// need to support version skew yet; a range check can replace this if that changes.
    public var isProtocolVersionCompatible: Bool {
        self.protocolVersion == SpeakTransportProtocolVersion
    }
}

public struct AuthenticateMessage: Codable {
    public var pairingCode: String
    public var timestamp: Date

    public init(pairingCode: String, timestamp: Date = Date()) {
        self.pairingCode = pairingCode
        self.timestamp = timestamp
    }
}

public struct AuthResultMessage: Codable {
    public var success: Bool
    public var sessionToken: String?
    public var errorMessage: String?

    public init(success: Bool, sessionToken: String? = nil, errorMessage: String? = nil) {
        self.success = success
        self.sessionToken = sessionToken
        self.errorMessage = errorMessage
    }
}

public struct SessionStartMessage: Codable {
    public var sessionId: String
    public var model: String
    public var language: String

    public init(sessionId: String, model: String, language: String = "en-US") {
        self.sessionId = sessionId
        self.model = model
        self.language = language
    }
}

public struct SessionEndMessage: Codable {
    public var sessionId: String
    public var finalText: String
    public var duration: TimeInterval
    public var wordCount: Int

    public init(sessionId: String, finalText: String, duration: TimeInterval, wordCount: Int) {
        self.sessionId = sessionId
        self.finalText = finalText
        self.duration = duration
        self.wordCount = wordCount
    }
}

public struct TranscriptChunkMessage: Codable {
    public var sessionId: String
    public var sequenceNumber: Int
    public var text: String
    public var isFinal: Bool
    public var timestamp: Date

    public init(sessionId: String, sequenceNumber: Int, text: String, isFinal: Bool, timestamp: Date = Date()) {
        self.sessionId = sessionId
        self.sequenceNumber = sequenceNumber
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
    }
}

public struct AckMessage: Codable {
    public var sequenceNumber: Int

    public init(sequenceNumber: Int) {
        self.sequenceNumber = sequenceNumber
    }
}

public struct ErrorMessage: Codable, Sendable {
    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static let authenticationFailed = ErrorMessage(code: 401, message: "Authentication failed")
    public static let protocolMismatch = ErrorMessage(code: 400, message: "Protocol version mismatch")
    public static let sessionNotFound = ErrorMessage(code: 404, message: "Session not found")

    /// Protocol-mismatch error that tells the client both versions, so the rejection
    /// is actionable ("update the app") instead of a silent disconnect.
    public static func protocolMismatch(
        clientVersion: Int,
        serverVersion: Int = SpeakTransportProtocolVersion
    ) -> ErrorMessage {
        ErrorMessage(
            code: ErrorMessage.protocolMismatch.code,
            message: "Protocol version mismatch: client sent v\(clientVersion), server requires v\(serverVersion)"
        )
    }
}

// MARK: - Pairing

/// Manages pairing codes for device authentication.
///
/// `@unchecked` only because `UserDefaults` lacks a Sendable annotation in the
/// SDK. Every pairing-code and paired-device transaction is serialized behind
/// one `NSLock` — `UserDefaults` alone is thread-safe per call, but the
/// read-modify-write sequences here need a single owner to avoid losing
/// entries or minting competing codes.
public final class PairingManager: @unchecked Sendable {
    public static let shared = PairingManager()

    private let defaults = UserDefaults.standard
    private let pairingCodeKey = "speakTransportPairingCode"
    private let pairedDevicesKey = "speakTransportPairedDevices"
    /// Serializes all read-modify-write transactions below. Not reentrant:
    /// public members take it once and only call `...Unlocked` helpers inside.
    private let lock = NSLock()

    private init() {}

    /// Gets or generates the pairing code for this device.
    public var pairingCode: String {
        lock.withLock { pairingCodeUnlocked() }
    }

    /// Regenerates the pairing code (invalidates all existing pairings).
    public func regeneratePairingCode() -> String {
        lock.withLock {
            let code = generatePairingCode()
            defaults.set(code, forKey: pairingCodeKey)
            defaults.removeObject(forKey: pairedDevicesKey)
            return code
        }
    }

    /// Validates a pairing code.
    public func validatePairingCode(_ code: String) -> Bool {
        lock.withLock { code == pairingCodeUnlocked() }
    }

    /// Records a paired device.
    public func addPairedDevice(id: String, name: String) {
        lock.withLock {
            var devices = pairedDevicesUnlocked()
            devices[id] = name
            defaults.set(devices, forKey: pairedDevicesKey)
        }
    }

    /// Removes a paired device.
    public func removePairedDevice(id: String) {
        lock.withLock {
            var devices = pairedDevicesUnlocked()
            devices.removeValue(forKey: id)
            defaults.set(devices, forKey: pairedDevicesKey)
        }
    }

    /// Gets all paired devices.
    public var pairedDevices: [String: String] {
        lock.withLock { pairedDevicesUnlocked() }
    }

    /// Checks if a device is paired.
    public func isDevicePaired(id: String) -> Bool {
        lock.withLock { pairedDevicesUnlocked()[id] != nil }
    }

    private func pairingCodeUnlocked() -> String {
        if let existing = defaults.string(forKey: pairingCodeKey) {
            return existing
        }
        let code = generatePairingCode()
        defaults.set(code, forKey: pairingCodeKey)
        return code
    }

    private func pairedDevicesUnlocked() -> [String: String] {
        defaults.dictionary(forKey: pairedDevicesKey) as? [String: String] ?? [:]
    }

    private func generatePairingCode() -> String {
        // Generate 6-digit numeric code
        String(format: "%06d", Int.random(in: 0...999999))
    }
}

// MARK: - Device Identity

/// Provides consistent device identification.
public struct DeviceIdentity {
    public static var deviceId: String {
        #if os(iOS)
        // Keep any previously persisted ID so existing pairings survive.
        if let id = UserDefaults.standard.string(forKey: "speakDeviceId") {
            return id
        }
        // Prefer identifierForVendor: stable across reinstalls while any app
        // from the same vendor remains installed, unlike a random UUID.
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "speakDeviceId")
        return id
        #else
        // On macOS, use hardware UUID
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }

        if let serialNumber = IORegistryEntryCreateCFProperty(
            platformExpert,
            kIOPlatformUUIDKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String {
            return serialNumber
        }
        return UUID().uuidString
        #endif
    }

    public static var deviceName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif
