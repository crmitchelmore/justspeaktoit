import Foundation

// MARK: - Failures

/// Why a per-run capture parameter was refused.
///
/// Every case here stops the microphone from opening. That is the point: a
/// caller that named a language or model this app does not have must be told,
/// not quietly given a different one. A Shortcut cannot see an alert and the
/// user cannot see the Shortcut's inputs, so the message has to work in both
/// places — it is the intent's error dialog and the log line.
///
/// The raw values match the `errorCode` vocabulary the capture URL surface
/// (#1070) hands back to an x-callback-url caller, so one automation that uses
/// both surfaces sees one set of names.
public enum CaptureParameterFailure: String, Error, LocalizedError, Equatable, Sendable, CaseIterable {
    /// A language parameter named something outside the language catalogue.
    case unknownLanguage
    /// A model parameter named something outside the transcription catalogue.
    case unknownModel
    /// A named model exists, but no credential for it is available on this
    /// device, so honouring the request would mean recording with a different
    /// model than the caller asked for.
    case modelUnavailable
    /// A source tag was present but unusable (blank, or control characters).
    case invalidSource

    public var errorDescription: String? {
        switch self {
        case .unknownLanguage:
            return "That language is not one this app knows. The recording was not started."
        case .unknownModel:
            return "That transcription model is not one this app knows. The recording was not started."
        case .modelUnavailable:
            return "That transcription model needs an API key this device does not have. "
                + "The recording was not started."
        case .invalidSource:
            return "The source tag was blank or contained characters this app will not store."
        }
    }
}

// MARK: - Resolution

/// Pure validation and precedence for the per-run capture parameters:
/// destination, language, model and a caller-supplied source tag.
///
/// Nothing here falls back to a default when a value is *wrong*. A `nil`
/// return always means "refuse", never "use the global setting" — the caller
/// distinguishes the two by whether the parameter was supplied at all. Silent
/// substitution is the failure mode this whole unit exists to prevent.
///
/// `language`, `model` and `requiresBatchMode` implement exactly the rules the
/// capture URL surface established in #1070 (`CaptureLinkParameters`). Both
/// stacks landed together, so this is the single implementation and
/// `CaptureLinkParameters` forwards to it: `lang=en_GB` in a URL and
/// "Language: English (United Kingdom)" in a Shortcut can never mean
/// different things.
public enum CaptureParameterResolution {
    /// Longest source tag kept. A tag is a label for a person's own
    /// automation ("car NFC", "desk tag"), not a payload.
    public static let maxSourceTagLength = 64

    /// Accepts a language identifier from the catalogue (`en_US`, and `en-US`
    /// for callers that write BCP-47 with a hyphen), or `auto`/`automatic` for
    /// provider-side detection.
    ///
    /// A bare `en` is rejected on purpose: the catalogue holds four English
    /// locales and picking one would be exactly the silent substitution this
    /// parameter must not make.
    public static func language(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "-", with: "_").lowercased()
        if normalized == "auto" || normalized == TranscriptionLanguageCatalog.automaticIdentifier {
            return TranscriptionLanguageCatalog.automaticIdentifier
        }
        return TranscriptionLanguageCatalog.options
            .first { $0.id.lowercased() == normalized }?
            .id
    }

    /// Accepts a transcription model identifier that the catalogue lists for
    /// live or batch transcription. The "custom model" placeholder is not a
    /// real identifier, so it is rejected too.
    public static func model(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != ModelCatalog.customOptionID else { return nil }
        let options = ModelCatalog.liveTranscription
            + ModelCatalog.batchTranscription
            + ModelCatalog.localTranscriptionOptions
        return options.first { $0.id.lowercased() == trimmed.lowercased() }?.id
    }

    /// Whether the identifier is a batch-only model, so the capture has to run
    /// in batch mode however the app is configured. `false` when the model is
    /// available live, which leaves the configured mode alone.
    public static func requiresBatchMode(_ modelID: String) -> Bool {
        let isLive = (ModelCatalog.liveTranscription + ModelCatalog.localTranscriptionOptions)
            .contains { $0.id.lowercased() == modelID.lowercased() }
        return !isLive
    }

    /// Normalises a caller-supplied source tag: whitespace trimmed and
    /// collapsed, capped at `maxSourceTagLength`. Returns `nil` for a blank
    /// tag or one carrying control characters, which the caller turns into a
    /// visible refusal rather than storing something unprintable.
    public static func sourceTag(from raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard !collapsed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return String(collapsed.prefix(maxSourceTagLength))
    }

    /// Precedence for the destination a stop should use.
    ///
    /// Explicit beats remembered beats global: a Stop that names a
    /// destination wins, otherwise the override the *start* carried travels
    /// with the run so an interruption, a Live Activity button or a quick
    /// action all finish where the caller asked, and only then does the one
    /// global setting apply.
    public static func stopDestinationID(
        explicit: String?,
        runOverride: String?,
        global: String
    ) -> String {
        explicit ?? runOverride ?? global
    }

    /// Validates the four parameters together.
    ///
    /// A `nil` argument means "the caller did not supply this one", and the
    /// resolved value stays `nil` so the run falls through to today's
    /// behaviour untouched. Supplying nothing therefore produces
    /// `CaptureRunParameters.none`, which is indistinguishable from the
    /// pre-parameter code path.
    ///
    /// - Throws: `CaptureParameterFailure` for a value that was supplied and
    ///   is not recognised.
    public static func resolve(
        destinationID: String? = nil,
        language rawLanguage: String? = nil,
        model rawModel: String? = nil,
        source rawSource: String? = nil
    ) throws -> CaptureRunParameters {
        var languageIdentifier: String?
        if let rawLanguage {
            guard let resolved = self.language(from: rawLanguage) else {
                throw CaptureParameterFailure.unknownLanguage
            }
            languageIdentifier = resolved
        }

        var modelID: String?
        if let rawModel {
            guard let resolved = self.model(from: rawModel) else {
                throw CaptureParameterFailure.unknownModel
            }
            modelID = resolved
        }

        var sourceTag: String?
        if let rawSource {
            guard let resolved = self.sourceTag(from: rawSource) else {
                throw CaptureParameterFailure.invalidSource
            }
            sourceTag = resolved
        }

        return CaptureRunParameters(
            destinationID: destinationID,
            languageIdentifier: languageIdentifier,
            modelID: modelID,
            sourceTag: sourceTag
        )
    }
}

// MARK: - Run parameters

/// The per-run overrides a single capture carries from the surface that
/// started it to every surface that can finish it.
///
/// Identifiers rather than typed enums, deliberately: the destination enum and
/// the settings store live in the iOS app layer, and keeping this struct made
/// of strings is what lets the precedence and validation rules be unit-tested
/// on the host instead of only on a device.
public struct CaptureRunParameters: Equatable, Sendable {
    /// `HardwareTriggerDestination.rawValue`, or `nil` to use the global
    /// setting exactly as before.
    public let destinationID: String?
    /// A `TranscriptionLanguageCatalog` identifier, or `nil` for the global
    /// language preference.
    public let languageIdentifier: String?
    /// A `ModelCatalog` transcription identifier, or `nil` for the configured
    /// model.
    public let modelID: String?
    /// A label the caller chose for its own automation. Diagnostic only: it is
    /// logged with the run so a user can tell which of several automations
    /// started a capture. It never changes behaviour, and it is never treated
    /// as evidence that a trigger works — `CaptureTrigger` stays the only
    /// thing that can prove that, because it is the only one the app observes
    /// rather than being told.
    public let sourceTag: String?

    public init(
        destinationID: String? = nil,
        languageIdentifier: String? = nil,
        modelID: String? = nil,
        sourceTag: String? = nil
    ) {
        self.destinationID = destinationID
        self.languageIdentifier = languageIdentifier
        self.modelID = modelID
        self.sourceTag = sourceTag
    }

    /// No overrides at all — a run that behaves exactly as it did before any
    /// parameter existed.
    public static let none = CaptureRunParameters()

    /// Whether the caller supplied anything. A run with nothing set takes
    /// every pre-existing code path unchanged.
    public var isEmpty: Bool { self == .none }

    /// Whether the explicitly requested model forces batch transcription.
    /// `false` when no model was requested, so the configured mode stands.
    public var requiresBatchMode: Bool {
        guard let modelID else { return false }
        return CaptureParameterResolution.requiresBatchMode(modelID)
    }

    /// One-line description for the log, so a capture's parameters are
    /// recoverable after the fact. Empty when nothing was overridden.
    public var logDescription: String {
        var parts: [String] = []
        if let destinationID { parts.append("destination=\(destinationID)") }
        if let languageIdentifier { parts.append("language=\(languageIdentifier)") }
        if let modelID { parts.append("model=\(modelID)") }
        if let sourceTag { parts.append("source=\(sourceTag)") }
        return parts.joined(separator: " ")
    }
}
