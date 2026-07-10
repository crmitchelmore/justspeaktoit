// swiftlint:disable file_length
import Combine
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

// MARK: - Transport Protocol

// swiftlint:disable identifier_name
/// Multipeer Connectivity service type for local transport discovery.
public let SpeakTransportServiceType = "speaktransport"

/// Bonjour service entries required in app Info.plists for the MPC service.
public let SpeakTransportBonjourTCPService = "_speaktransport._tcp"
public let SpeakTransportBonjourUDPService = "_speaktransport._udp"
public let SpeakTransportBonjourServices = [
    SpeakTransportBonjourTCPService,
    SpeakTransportBonjourUDPService
]

/// Protocol version for compatibility checking
public let SpeakTransportProtocolVersion = 2
// swiftlint:enable identifier_name

/// Validates the constrained MPC service-type format before frameworks are involved.
public func isValidSpeakTransportServiceType(_ serviceType: String) -> Bool {
    guard (1...15).contains(serviceType.count) else { return false }
    guard !serviceType.hasPrefix("-"), !serviceType.hasSuffix("-") else { return false }
    return serviceType.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
}

// MARK: - Message Types

/// Messages exchanged between iOS and macOS over the encrypted local transport.
public enum TransportMessage: Codable {
    case hello(HelloMessage)
    case authenticate(AuthenticateMessage)
    case authResult(AuthResultMessage)
    case sessionStart(SessionStartMessage)
    case sessionEnd(SessionEndMessage)
    case transcriptChunk(TranscriptChunkMessage)
    case historySyncRequest(HistorySyncRequestMessage)
    case historySyncBatch(HistorySyncBatchMessage)
    case historySyncComplete(HistorySyncCompleteMessage)
    case settingsSyncRequest(SettingsSyncRequestMessage)
    case settingsSyncBatch(SettingsSyncBatchMessage)
    case settingsSyncComplete(SettingsSyncCompleteMessage)
    case ack(AckMessage)
    case error(ErrorMessage)
    case ping
    case pong
    case unknown(type: String)
    
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }
    
    private enum MessageType: String, Codable {
        case hello, authenticate, authResult
        case sessionStart, sessionEnd
        case transcriptChunk, historySyncRequest, historySyncBatch, historySyncComplete
        case settingsSyncRequest, settingsSyncBatch, settingsSyncComplete
        case ack, error
        case ping, pong
    }
    
    // swiftlint:disable:next cyclomatic_complexity
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let type = MessageType(rawValue: rawType) else {
            self = .unknown(type: rawType)
            return
        }
        
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
        case .historySyncRequest:
            self = .historySyncRequest(try container.decode(HistorySyncRequestMessage.self, forKey: .payload))
        case .historySyncBatch:
            self = .historySyncBatch(try container.decode(HistorySyncBatchMessage.self, forKey: .payload))
        case .historySyncComplete:
            self = .historySyncComplete(try container.decode(HistorySyncCompleteMessage.self, forKey: .payload))
        case .settingsSyncRequest:
            self = .settingsSyncRequest(try container.decode(SettingsSyncRequestMessage.self, forKey: .payload))
        case .settingsSyncBatch:
            self = .settingsSyncBatch(try container.decode(SettingsSyncBatchMessage.self, forKey: .payload))
        case .settingsSyncComplete:
            self = .settingsSyncComplete(try container.decode(SettingsSyncCompleteMessage.self, forKey: .payload))
        case .ack:
            self = .ack(try container.decode(AckMessage.self, forKey: .payload))
        case .error:
            self = .error(try container.decode(ErrorMessage.self, forKey: .payload))
        case .ping:
            self = .ping
        case .pong:
            self = .pong
        }
    }
    
    // swiftlint:disable:next cyclomatic_complexity function_body_length
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
        case .historySyncRequest(let msg):
            try container.encode(MessageType.historySyncRequest, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .historySyncBatch(let msg):
            try container.encode(MessageType.historySyncBatch, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .historySyncComplete(let msg):
            try container.encode(MessageType.historySyncComplete, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .settingsSyncRequest(let msg):
            try container.encode(MessageType.settingsSyncRequest, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .settingsSyncBatch(let msg):
            try container.encode(MessageType.settingsSyncBatch, forKey: .type)
            try container.encode(msg, forKey: .payload)
        case .settingsSyncComplete(let msg):
            try container.encode(MessageType.settingsSyncComplete, forKey: .type)
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
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

// MARK: - Message Payloads

public struct HelloMessage: Codable {
    public var protocolVersion: Int
    public var deviceName: String
    public var deviceId: String
    
    public init(protocolVersion: Int = SpeakTransportProtocolVersion, deviceName: String, deviceId: String) {
        self.protocolVersion = protocolVersion
        self.deviceName = deviceName
        self.deviceId = deviceId
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

// swiftlint:disable identifier_name
public let SpeakTransportHistoryMaxBatchSize = 100
public let SpeakTransportHistoryMaxSnapshotEntries = 5_000
public let SpeakTransportSettingsMaxBatchSize = 100
// swiftlint:enable identifier_name

public struct HistorySyncRequestMessage: Codable, Equatable {
    public var requestID: UUID
    public var requestedAt: Date

    public init(requestID: UUID = UUID(), requestedAt: Date = Date()) {
        self.requestID = requestID
        self.requestedAt = requestedAt
    }
}

public struct HistorySyncBatchMessage: Codable, Equatable {
    public var requestID: UUID
    public var batchIndex: Int
    public var isLast: Bool
    public var entries: [SyncableHistoryEntry]
    public var tombstones: [HistoryDeletionTombstone]

    public init(
        requestID: UUID,
        batchIndex: Int,
        isLast: Bool,
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) {
        self.requestID = requestID
        self.batchIndex = batchIndex
        self.isLast = isLast
        self.entries = Array(entries.prefix(SpeakTransportHistoryMaxBatchSize))
        let remaining = max(0, SpeakTransportHistoryMaxBatchSize - self.entries.count)
        self.tombstones = Array(tombstones.prefix(remaining))
    }

    public var itemCount: Int {
        entries.count + tombstones.count
    }

    public var isWithinBatchLimit: Bool {
        itemCount <= SpeakTransportHistoryMaxBatchSize
    }

    public static func batches(
        requestID: UUID,
        entries: [SyncableHistoryEntry],
        tombstones: [HistoryDeletionTombstone]
    ) -> [HistorySyncBatchMessage] {
        var remainingEntries = ArraySlice(entries)
        var remainingTombstones = ArraySlice(tombstones)
        var batches: [HistorySyncBatchMessage] = []
        var index = 0

        repeat {
            let entryChunk = Array(remainingEntries.prefix(SpeakTransportHistoryMaxBatchSize))
            remainingEntries = remainingEntries.dropFirst(entryChunk.count)
            let tombstoneCapacity = max(0, SpeakTransportHistoryMaxBatchSize - entryChunk.count)
            let tombstoneChunk = Array(remainingTombstones.prefix(tombstoneCapacity))
            remainingTombstones = remainingTombstones.dropFirst(tombstoneChunk.count)
            let isLast = remainingEntries.isEmpty && remainingTombstones.isEmpty
            batches.append(
                HistorySyncBatchMessage(
                    requestID: requestID,
                    batchIndex: index,
                    isLast: isLast,
                    entries: entryChunk,
                    tombstones: tombstoneChunk
                )
            )
            index += 1
        } while !remainingEntries.isEmpty || !remainingTombstones.isEmpty

        return batches
    }
}

public struct HistorySyncCompleteMessage: Codable, Equatable {
    public var requestID: UUID
    public var receivedBatchCount: Int
    public var completedAt: Date

    public init(requestID: UUID, receivedBatchCount: Int, completedAt: Date = Date()) {
        self.requestID = requestID
        self.receivedBatchCount = receivedBatchCount
        self.completedAt = completedAt
    }
}

public struct SettingsSyncRequestMessage: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var requestedAt: Date

    public init(requestID: UUID = UUID(), requestedAt: Date = Date()) {
        self.requestID = requestID
        self.requestedAt = requestedAt
    }
}

public struct SettingsSyncBatchMessage: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var batchIndex: Int
    public var isLast: Bool
    public var records: [SyncedSettingRecord]

    public init(requestID: UUID, batchIndex: Int, isLast: Bool, records: [SyncedSettingRecord]) {
        self.requestID = requestID
        self.batchIndex = batchIndex
        self.isLast = isLast
        self.records = Array(records.prefix(SpeakTransportSettingsMaxBatchSize))
    }

    public var isWithinBatchLimit: Bool {
        records.count <= SpeakTransportSettingsMaxBatchSize
    }

    public static func batches(requestID: UUID, records: [SyncedSettingRecord]) -> [SettingsSyncBatchMessage] {
        var remaining = ArraySlice(records)
        var batches: [SettingsSyncBatchMessage] = []
        var index = 0

        repeat {
            let chunk = Array(remaining.prefix(SpeakTransportSettingsMaxBatchSize))
            remaining = remaining.dropFirst(chunk.count)
            batches.append(
                SettingsSyncBatchMessage(
                    requestID: requestID,
                    batchIndex: index,
                    isLast: remaining.isEmpty,
                    records: chunk
                )
            )
            index += 1
        } while !remaining.isEmpty

        return batches
    }
}

public struct SettingsSyncCompleteMessage: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var receivedBatchCount: Int
    public var completedAt: Date

    public init(requestID: UUID, receivedBatchCount: Int, completedAt: Date = Date()) {
        self.requestID = requestID
        self.receivedBatchCount = receivedBatchCount
        self.completedAt = completedAt
    }
}

public struct AckMessage: Codable {
    public var sequenceNumber: Int
    
    public init(sequenceNumber: Int) {
        self.sequenceNumber = sequenceNumber
    }
}

public struct ErrorMessage: Codable {
    public var code: Int
    public var message: String
    
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    
    public static let authenticationFailed = ErrorMessage(code: 401, message: "Authentication failed")
    public static let protocolMismatch = ErrorMessage(code: 400, message: "Protocol version mismatch")
    public static let sessionNotFound = ErrorMessage(code: 404, message: "Session not found")
}

// MARK: - Invitation Context

/// Authentication context sent in the MPC invitation before a session is accepted.
public struct PairingInvitationContext: Codable, Equatable {
    public var protocolVersion: Int
    public var deviceID: String
    public var deviceName: String
    public var timestamp: Date
    public var pairingCode: String

    public init(
        protocolVersion: Int = SpeakTransportProtocolVersion,
        deviceID: String,
        deviceName: String,
        timestamp: Date = Date(),
        pairingCode: String
    ) {
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.timestamp = timestamp
        self.pairingCode = pairingCode
    }

    public func isFresh(
        now: Date = Date(),
        tolerance: TimeInterval = PairingManager.defaultInvitationFreshness
    ) -> Bool {
        abs(now.timeIntervalSince(timestamp)) <= tolerance
    }
}

// MARK: - Pairing

/// Manages pairing codes for device authentication.
public final class PairingManager: ObservableObject {
    public static let shared = PairingManager()
    
    public static let defaultPairingCodeLifetime: TimeInterval = 10 * 60
    public static let defaultInvitationFreshness: TimeInterval = 2 * 60

    private let defaults: UserDefaults
    private let now: () -> Date
    private let codeLifetime: TimeInterval
    private let codeGenerator: () -> String
    private let pairingCodeKey = "speakTransportPairingCode"
    private let pairingCodeExpirationKey = "speakTransportPairingCodeExpiration"
    private let pairedDevicesKey = "speakTransportPairedDevices"

    @Published public private(set) var currentPairingCode: String
    @Published public private(set) var pairingCodeExpiresAt: Date
    
    public init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        codeLifetime: TimeInterval = PairingManager.defaultPairingCodeLifetime,
        codeGenerator: @escaping () -> String = PairingManager.generateSecurePairingCode
    ) {
        self.defaults = defaults
        self.now = now
        self.codeLifetime = codeLifetime
        self.codeGenerator = codeGenerator
        self.currentPairingCode = defaults.string(forKey: pairingCodeKey) ?? ""
        self.pairingCodeExpiresAt =
            defaults.object(forKey: pairingCodeExpirationKey) as? Date ?? .distantPast
        if currentPairingCode.isEmpty || pairingCodeExpiresAt <= now() {
            _ = generateAndPersistPairingCode(clearPairedDevices: false)
        }
    }
    
    /// Gets or generates the pairing code for this device.
    public var pairingCode: String {
        if pairingCodeExpiresAt > now() {
            return currentPairingCode
        }
        return generateAndPersistPairingCode(clearPairedDevices: false)
    }
    
    /// Regenerates the pairing code (invalidates all existing pairings).
    public func regeneratePairingCode() -> String {
        generateAndPersistPairingCode(clearPairedDevices: true)
    }

    /// Rotates the one-time pairing code after a successful pairing without removing trusted devices.
    @discardableResult
    public func rotateAfterSuccessfulPairing() -> String {
        generateAndPersistPairingCode(clearPairedDevices: false)
    }
    
    /// Validates a pairing code.
    public func validatePairingCode(_ code: String) -> Bool {
        guard pairingCodeExpiresAt > now() else {
            return false
        }
        return Self.normalizedPairingCode(code) == Self.normalizedPairingCode(currentPairingCode)
    }
    
    /// Records a paired device.
    public func addPairedDevice(id: String, name: String) {
        var devices = pairedDevices
        devices[id] = name
        savePairedDevices(devices)
    }
    
    /// Removes a paired device.
    public func removePairedDevice(id: String) {
        var devices = pairedDevices
        devices.removeValue(forKey: id)
        savePairedDevices(devices)
    }
    
    /// Gets all paired devices.
    public var pairedDevices: [String: String] {
        defaults.dictionary(forKey: pairedDevicesKey) as? [String: String] ?? [:]
    }
    
    /// Checks if a device is paired.
    public func isDevicePaired(id: String) -> Bool {
        pairedDevices[id] != nil
    }
    
    public static func normalizedPairingCode(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    private func generateAndPersistPairingCode(clearPairedDevices: Bool) -> String {
        let code = codeGenerator()
        let expiration = now().addingTimeInterval(codeLifetime)
        currentPairingCode = code
        pairingCodeExpiresAt = expiration
        defaults.set(code, forKey: pairingCodeKey)
        defaults.set(expiration, forKey: pairingCodeExpirationKey)
        if clearPairedDevices {
            defaults.removeObject(forKey: pairedDevicesKey)
        }
        return code
    }

    public static func generateSecurePairingCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<10).map { _ in
            alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]
        }
        return String(characters.prefix(5)) + "-" + String(characters.suffix(5))
    }
    
    private func savePairedDevices(_ devices: [String: String]) {
        defaults.set(devices, forKey: pairedDevicesKey)
    }
}

// MARK: - Device Identity

/// Provides consistent device identification.
public struct DeviceIdentity {
    public static var deviceId: String {
        #if os(iOS)
        if let id = UserDefaults.standard.string(forKey: "speakDeviceId") {
            return id
        }
        let id = UUID().uuidString
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
