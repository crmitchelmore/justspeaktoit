import Foundation
import SpeakCore

/// A filename or HF library tag is not proof of format. Check the fixed
/// little-endian Whisper GGML header after the full pinned digest is verified.
/// Tensor completeness and decoding remain the native runtime's responsibility.
public enum WhisperGGMLImportValidation {
    // existing owned architecture lookup table; no behavior change.
    // swiftlint:disable:next large_tuple
    private static let architectures: [(prefix: String, state: Int, heads: Int, layers: Int)] = [
        ("ggml-tiny", 384, 6, 4), ("ggml-base", 512, 8, 6), ("ggml-small", 768, 12, 12),
        ("ggml-medium", 1_024, 16, 24), ("ggml-large-v", 1_280, 20, 32)
    ]

    public static func validate(_ file: URL, filename: String) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HuggingFaceWhisperError.incompatibleHeader
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 48) ?? Data()
        try validate(header: header, filename: filename)
    }

    public static func validate(header: Data, filename: String) throws {
        try HuggingFaceWhisperModel.validateInput(repository: "fixture/whisper", filename: filename)
        let bytes = [UInt8](header)
        guard bytes.count == 48 else { throw HuggingFaceWhisperError.incompatibleHeader }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard let architecture = architectures.first(where: { filename.hasPrefix($0.prefix) }) else {
            throw HuggingFaceWhisperError.incompatibleHeader
        }
        let (state, heads, layers) = (architecture.state, architecture.heads, architecture.layers)
        let english = filename.contains(".en")
        let isLargeV3 = filename.hasPrefix("ggml-large-v3")
        let decoderLayers = filename.contains("-turbo") ? 4 : layers
        let types: [String: Int] = ["q4_0": 2, "q4_1": 3, "q8_0": 7, "q5_0": 8, "q5_1": 9]
        let quantization = String(filename.dropLast(4).suffix(4))
        let allowedTypes = types[quantization].map { [$0] } ?? [0, 1]
        guard word(0) == 0x6767_6D6C,
              word(4) == (english ? 51_864 : isLargeV3 ? 51_866 : 51_865),
              word(8) == 1_500, word(12) == state, word(16) == heads, word(20) == layers,
              word(24) == 448, word(28) == state, word(32) == heads, word(36) == decoderLayers,
              word(40) == (isLargeV3 ? 128 : 80),
              allowedTypes.contains(word(44) % 1_000), word(44) / 1_000 <= 2 else {
            throw HuggingFaceWhisperError.incompatibleHeader
        }
    }
}
