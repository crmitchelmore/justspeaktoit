import Foundation

/// A Microsoft AI (MAI) text-to-speech model served through Azure Speech.
///
/// MAI voices use the same regional synthesis endpoint, key and SSML contract
/// as Azure neural voices. The model is chosen by the voice-name suffix, for
/// example `en-US-Harper:MAI-Voice-2.1-Flash`, so there is no separate model
/// field and no extra credential.
///
/// Only the models Microsoft currently documents are listed. An older MAI
/// voice a resource still lists (MAI-Voice-2, MAI-Voice-1) stays usable by
/// name, with its price shown as unknown rather than guessed.
public enum AzureMAIVoiceModel: String, CaseIterable, Codable, Hashable, Sendable {
    /// Highest-fidelity MAI voice, suited to long-form reading.
    case voice21 = "MAI-Voice-2.1"
    /// Low-latency MAI voice for quick spoken replies.
    case voice21Flash = "MAI-Voice-2.1-Flash"

    /// Microsoft's own product name, which is also the SSML suffix.
    public var displayName: String { rawValue }

    public var isLowLatency: Bool { self == .voice21Flash }

    /// Published pay-as-you-go price in US dollars per million characters
    /// (microsoft.ai, 1 October 2026).
    public var costPerMillionCharacters: Decimal {
        switch self {
        case .voice21: Decimal(22)
        case .voice21Flash: Decimal(15)
        }
    }
}

public enum AzureMAIVoiceGender: String, Codable, Hashable, Sendable {
    case female
    case male
}

/// One prebuilt MAI speaker paired with one MAI model.
public struct AzureMAIVoice: Identifiable, Hashable, Sendable {
    public let speaker: String
    public let locale: String
    public let gender: AzureMAIVoiceGender
    public let model: AzureMAIVoiceModel

    public init(speaker: String, locale: String, gender: AzureMAIVoiceGender, model: AzureMAIVoiceModel) {
        self.speaker = speaker
        self.locale = locale
        self.gender = gender
        self.model = model
    }

    /// The SSML voice name Azure expects, e.g. `en-US-Harper:MAI-Voice-2.1`.
    public var shortName: String { "\(locale)-\(speaker):\(model.rawValue)" }

    /// The stored identifier, routed to Azure by its `azure/` prefix. Matches
    /// `AzureSpeechVoice.id` for the same voice from a resource listing.
    public var id: String { AzureMAIVoiceCatalog.voiceIDPrefix + shortName }

    public var displayName: String {
        AzureMAIVoiceCatalog.displayName(speaker: speaker, locale: locale, model: model.rawValue)
    }
}

/// Canonical catalogue of MAI voices offered through Azure Speech.
///
/// A resource's own voice listing stays authoritative for everything else it
/// offers, including other locales and superseded models. These curated
/// English speakers keep the current MAI models selectable offline and before
/// that listing loads. Microsoft documents MAI-Voice-2.1 and Flash as globally
/// accessible, routed to the regions that serve them, so they are offered even
/// when a regional listing omits them. See `Docs/azure-speech.md`.
public enum AzureMAIVoiceCatalog {
    /// Prefix that routes a stored voice identifier to Azure.
    public static let voiceIDPrefix = "azure/"
    /// What every MAI voice name carries between the speaker and the model.
    public static let modelMarker = ":MAI-Voice-"

    private struct Speaker: Sendable {
        let name: String
        let locale: String
        let gender: AzureMAIVoiceGender
    }

    /// Managed speakers Microsoft lists for both MAI-Voice-2.1 models.
    private static let speakers: [Speaker] = [
        Speaker(name: "Harper", locale: "en-US", gender: .female),
        Speaker(name: "Olivia", locale: "en-US", gender: .female),
        Speaker(name: "Grant", locale: "en-US", gender: .male),
        Speaker(name: "Ethan", locale: "en-US", gender: .male),
        Speaker(name: "Emily", locale: "en-GB", gender: .female),
        Speaker(name: "Harry", locale: "en-GB", gender: .male),
        Speaker(name: "Isla", locale: "en-AU", gender: .female),
        Speaker(name: "Priya", locale: "en-IN", gender: .female)
    ]

    /// Every curated speaker with each current model, speaker by speaker.
    public static let voices: [AzureMAIVoice] = speakers.flatMap { speaker in
        AzureMAIVoiceModel.allCases.map { model in
            AzureMAIVoice(speaker: speaker.name, locale: speaker.locale, gender: speaker.gender, model: model)
        }
    }

    /// Whether a stored identifier or SSML voice name selects any MAI model,
    /// including one this catalogue does not know yet.
    public static func isMAIVoice(_ voice: String) -> Bool {
        voice.contains(modelMarker)
    }

    /// The SSML voice name, without the `azure/` routing prefix.
    public static func shortName(forVoiceID voiceID: String) -> String {
        voiceID.hasPrefix(voiceIDPrefix) ? String(voiceID.dropFirst(voiceIDPrefix.count)) : voiceID
    }

    /// The known MAI model a voice selects, or nil for neural voices and for
    /// MAI models without a catalogue entry.
    public static func model(forVoiceID voiceID: String) -> AzureMAIVoiceModel? {
        guard isMAIVoice(voiceID), let suffix = voiceID.split(separator: ":").last else { return nil }
        return AzureMAIVoiceModel(rawValue: String(suffix))
    }

    /// "Harper (en-US, MAI-Voice-2.1)". Several locales share a speaker name,
    /// so the locale is what tells their voices apart in a picker.
    public static func displayName(speaker: String, locale: String, model: String) -> String {
        "\(speaker) (\(locale), \(model))"
    }

    /// A friendly name read from the identifier alone, for an MAI voice that
    /// only a resource listing offered. Nil for anything that is not an MAI
    /// voice name of the form `<locale>-<speaker>:<model>`, where the locale
    /// has at least a language and a region.
    public static func displayName(forVoiceID voiceID: String) -> String? {
        guard isMAIVoice(voiceID) else { return nil }
        let parts = shortName(forVoiceID: voiceID).split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        // Azure locales can carry a script or variant (`zh-Hans-CN`,
        // `zh-CN-sichuan`), so the speaker is the last component, not the third.
        let nameParts = parts[0].split(separator: "-")
        guard nameParts.count >= 3, let speaker = nameParts.last else { return nil }
        let locale = nameParts.dropLast().joined(separator: "-")
        return displayName(speaker: String(speaker), locale: locale, model: String(parts[1]))
    }

    /// Published price per 1,000 characters, or nil when the voice is not a
    /// known MAI model.
    public static func costPerThousandCharacters(forVoiceID voiceID: String) -> Decimal? {
        model(forVoiceID: voiceID).map { $0.costPerMillionCharacters / 1000 }
    }

    /// Estimated spend for `characterCount` characters, or nil when unknown.
    public static func estimatedCost(forVoiceID voiceID: String, characterCount: Int) -> Decimal? {
        costPerThousandCharacters(forVoiceID: voiceID).map { Decimal(characterCount) * $0 / 1000 }
    }

    /// Curated voices a resource listing left out, in catalogue order.
    public static func voicesMissing(fromListedIDs listedIDs: Set<String>) -> [AzureMAIVoice] {
        voices.filter { !listedIDs.contains($0.id) }
    }
}
