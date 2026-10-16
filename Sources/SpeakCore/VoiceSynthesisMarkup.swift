import Foundation

/// Examples from the Mac SSML helper. Availability belongs to the executable
/// provider capability, not to the presence of these editing examples.
public enum VoiceSynthesisMarkup {
    private static let openingTag = "<speak>"
    private static let closingTag = "</speak>"
    public struct Example: Sendable {
        public let text: String
        public let description: String
    }

    public static let examples: [Example] = [
        .init(text: "<speak>Your text here</speak>", description: "Root tag (required)"),
        .init(text: "<break time='500ms'/>", description: "Pause for duration"),
        .init(text: "<emphasis level='strong'>text</emphasis>", description: "Emphasize text"),
        .init(text: "<prosody rate='slow' pitch='+2st'>text</prosody>", description: "Control rate and pitch"),
        .init(text: "<say-as interpret-as='digits'>123</say-as>", description: "Number format"),
        .init(text: "<phoneme alphabet='ipa' ph='təˈmeɪtoʊ'>tomato</phoneme>", description: "Pronunciation")
    ]

    public static func wrapping(_ text: String) -> String {
        let prefix = wrappingPrefix(text)
        return prefix.isEmpty ? text : prefix + text + closingTag
    }

    private static func wrappingPrefix(_ text: String) -> String { text.contains(openingTag) ? "" : openingTag }

    /// Pure native-editor bridge. Wraps the whole draft, exactly like the Mac
    /// helper; it does not escape, validate XML, or wrap only the selection.
    /// Offsets retain the selection of the original text in each native unit.
    public static func writeWrappedText(
        _ input: UnsafePointer<CChar>?, output: UnsafeMutablePointer<CChar>?, capacity: Int,
        leadingUTF16: UnsafeMutablePointer<Int32>?, leadingScalars: UnsafeMutablePointer<Int32>?
    ) -> Int32 {
        guard let input, let output, let leadingUTF16, let leadingScalars,
              capacity > 0, capacity <= 1_048_576,
              let text = String(validatingUTF8: input) else { return -1 }
        let wrapped = wrapping(text)
        let bytes = Array(wrapped.utf8CString)
        guard bytes.count <= capacity else { return -1 }
        // The Mac's exact marker test, not XML root recognition.
        let prefix = wrappingPrefix(text)
        bytes.withUnsafeBufferPointer { output.update(from: $0.baseAddress!, count: $0.count) }
        leadingUTF16.pointee = Int32(prefix.utf16.count)
        leadingScalars.pointee = Int32(prefix.unicodeScalars.count)
        return 0
    }
}

extension DesktopSpeechVoice {
    public var deliveryGuidance: String {
        let quality = qualityTitle + ". Quality does not guarantee a particular latency."
        guard capabilities.ssml else {
            return quality + "\nThis route uses plain text. SSML and separate style/instruction parameters are "
                + "not implemented by its current shared request contract. Unsupported controls remain stored."
        }
        return quality + "\nEnable Use SSML and edit the source text. Complete <speak> documents define their own "
            + "prosody: use normal speed/pitch sliders. Fragments can use the supported sliders. Provider-specific "
            + "SSML tag support still applies.\n"
            + VoiceSynthesisMarkup.examples.map { $0.description + ": " + $0.text }.joined(separator: "\n")
    }
}
