import Foundation

/// Stable Mac preference identifiers. Membership does not imply an installed native codec.
public enum VoiceAudioFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case mp3, m4a, wav

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .mp3: "MP3"
        case .m4a: "AAC (M4A)"
        case .wav: "WAV"
        }
    }

    public static let macDefault: Self = .mp3
    /// Absence is the pre-format native desktop contract, not a migration to Mac's MP3 default.
    public static let desktopLegacyDefault: Self = .wav
    public static let preferenceKey = ApplicationPreferenceKey.ttsOutputFormat.rawValue

    public static func storedValue(_ value: String?) throws -> Self {
        guard let value else { return desktopLegacyDefault }
        guard let format = Self(rawValue: value) else { throw VoiceAudioFormatError.unknownFormat(value) }
        return format
    }

    public static func preference(in values: [String: AnyCodable]) throws -> String? {
        guard let value = values[preferenceKey] else { return nil }
        guard case .string(let identifier) = value.storage else {
            throw DesktopConfigurationError.invalidField("Voice file format")
        }
        return identifier
    }

    public static var transferField: DesktopConfiguration.Field {
        .init(key: preferenceKey, title: "Voice file format", group: "Voice Output",
              kind: .choice(allCases.map { .init(value: $0.rawValue, title: $0.displayName) }),
              defaultValue: AnyCodable(.string(desktopLegacyDefault.rawValue)))
    }

    /// A container sanity check, not a replacement for the native codec's successful decode.
    public func validateContainer(_ data: Data) throws {
        guard !data.isEmpty, data.count <= DeepgramSpeechExport.maximumPCMBytes + 4_096 else {
            throw VoiceAudioFormatError.invalidContainer
        }
        let bytes = [UInt8](data)
        switch self {
        case .wav:
            guard bytes.count >= 44, data.prefix(4) == Data("RIFF".utf8),
                  data[8..<12] == Data("WAVE".utf8) else { throw VoiceAudioFormatError.invalidContainer }
        case .mp3:
            var offset = 0
            if bytes.count >= 10, data.prefix(3) == Data("ID3".utf8) {
                guard bytes[6...9].allSatisfy({ $0 < 128 }) else { throw VoiceAudioFormatError.invalidContainer }
                offset = 10 + bytes[6...9].reduce(0) { ($0 << 7) | Int($1) }
                if bytes[5] & 0x10 != 0 { offset += 10 }
            }
            guard offset <= bytes.count - 4, bytes[offset] == 0xFF, bytes[offset + 1] & 0xE0 == 0xE0,
                  bytes[offset + 1] & 0x18 != 0x08, bytes[offset + 1] & 0x06 == 0x02,
                  (1...14).contains(Int(bytes[offset + 2] >> 4)),
                  bytes[offset + 2] & 0x0C != 0x0C else { throw VoiceAudioFormatError.invalidContainer }
        case .m4a:
            try Self.validateM4A(bytes)
        }
    }

    private static func validateM4A(_ bytes: [UInt8]) throws {
        var offset = 0
        var boxes = Set<String>()
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw VoiceAudioFormatError.invalidContainer }
            var size = bytes[offset..<offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let name = String(decoding: bytes[offset + 4..<offset + 8], as: UTF8.self)
            var headerSize: UInt64 = 8
            if size == 1 {
                guard bytes.count - offset >= 16 else { throw VoiceAudioFormatError.invalidContainer }
                size = bytes[offset + 8..<offset + 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size == 0, name == "mdat" { size = UInt64(bytes.count - offset) }
            guard size >= headerSize, size <= UInt64(bytes.count - offset) else {
                throw VoiceAudioFormatError.invalidContainer
            }
            boxes.insert(name)
            offset += Int(size)
        }
        guard boxes.isSuperset(of: ["ftyp", "moov", "mdat"]) else {
            throw VoiceAudioFormatError.invalidContainer
        }
    }
}

public enum VoiceAudioFormatError: LocalizedError, Sendable {
    case unknownFormat(String), unavailable(String), invalidContainer
    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let identifier):
            "Stored voice format '\(identifier)' is unavailable. Choose a supported format; the value was kept."
        case .unavailable(let reason): reason
        case .invalidContainer: "The native codec did not return a complete, supported voice audio container."
        }
    }
}
