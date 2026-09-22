import Foundation

/// A regular file inside a pinned archive, identified by its exact size and
/// SHA-256. `path` is relative to the archive's root directory and uses `/`.
public struct LocalModelPinnedFile: Hashable, Sendable {
    public let path: String
    public let byteCount: Int64
    /// Lowercase hexadecimal SHA-256 of the file contents.
    public let sha256: String

    public init(path: String, byteCount: Int64, sha256: String) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    /// The final path component, used for installed file names.
    public var filename: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// A downloadable archive qualified by exact bytes rather than by name.
///
/// The archive digest is checked before any byte is decompressed, and
/// extraction admits only the complete listing below: a different release,
/// an extra entry or a changed file is a different artefact, never a variant
/// of this one. Metadata here is not an execution capability by itself.
public struct LocalModelPinnedArchive: Hashable, Sendable {
    public enum Format: String, Sendable {
        /// A single bzip2 stream containing a POSIX or GNU tar archive of
        /// directories and regular files only.
        case tarBZip2 = "tar.bz2"
    }

    public let url: URL
    public let byteCount: Int64
    public let sha256: String
    public let format: Format
    /// The exact length of the decompressed tar stream, including padding.
    public let expandedByteCount: Int64
    public let rootDirectory: String
    /// Every directory below `rootDirectory`, relative to it.
    public let directories: [String]
    /// Every regular file in the archive, relative to `rootDirectory`.
    public let files: [LocalModelPinnedFile]

    public init(
        url: URL, byteCount: Int64, sha256: String, format: Format, expandedByteCount: Int64,
        rootDirectory: String, directories: [String], files: [LocalModelPinnedFile]
    ) {
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
        self.format = format
        self.expandedByteCount = expandedByteCount
        self.rootDirectory = rootDirectory
        self.directories = directories
        self.files = files
    }

    public func file(at path: String) -> LocalModelPinnedFile? {
        files.first { $0.path == path }
    }
}

/// The complete configuration of one sherpa-onnx offline NeMo transducer.
///
/// Parakeet TDT is an offline model: it decodes whole utterances. Its
/// catalogue identifier keeps the historical `local/streaming/` prefix
/// because that identifier is persisted; it is not a claim of online
/// streaming. Each file is qualified by digest before any native call,
/// because the sherpa-onnx loader exits the process on malformed metadata
/// or tokens instead of returning an error.
public struct SherpaOnnxOfflineRecognizerSpecification: Hashable, Sendable {
    public let sourceID: String
    public let displayName: String
    public let archive: LocalModelPinnedArchive
    public let tokens: LocalModelPinnedFile
    public let encoder: LocalModelPinnedFile
    public let decoder: LocalModelPinnedFile
    public let joiner: LocalModelPinnedFile
    public let modelType: String
    public let decodingMethod: String
    public let featureDimension: Int
    public let sampleRate: Int
    public let threadCount: Int
    public let provider: String
    public let license: String
    public let attribution: String

    /// The files the recognizer loads, in the order they are verified.
    public var runtimeFiles: [LocalModelPinnedFile] { [tokens, encoder, decoder, joiner] }
}

public extension ParakeetLocalModels {
    /// Exact archive length, measured from the pinned asset.
    static let tdtV3Int8ArchiveByteCount: Int64 = 487_170_055

    /// The pinned int8 Parakeet v3 archive and its recognizer settings. The
    /// values match the macOS sidecar (`nemo_transducer`, greedy search,
    /// 128-dimensional features at 16 kHz, two threads on the CPU).
    static let tdtV3Int8OfflineRecognizer: SherpaOnnxOfflineRecognizerSpecification = {
        let tokens = LocalModelPinnedFile(
            path: "tokens.txt", byteCount: 93_939,
            sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"
        )
        let joiner = LocalModelPinnedFile(
            path: "joiner.int8.onnx", byteCount: 6_355_277,
            sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"
        )
        let decoder = LocalModelPinnedFile(
            path: "decoder.int8.onnx", byteCount: 11_845_275,
            sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"
        )
        let encoder = LocalModelPinnedFile(
            path: "encoder.int8.onnx", byteCount: 652_184_281,
            sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"
        )
        let testAudio = [
            LocalModelPinnedFile(
                path: "test_wavs/en.wav", byteCount: 184_608,
                sha256: "148b936b43ce7c546a866e64da059f0458aee2d65e617f16e9d94f06e8d99ed6"
            ),
            LocalModelPinnedFile(
                path: "test_wavs/fr.wav", byteCount: 219_180,
                sha256: "b59be4349b92d344fb903677165eaf4694025d1ab119c608726ecbcb3164b528"
            ),
            LocalModelPinnedFile(
                path: "test_wavs/es.wav", byteCount: 235_052,
                sha256: "49fd2cfa4b62db7068143c582b35de9d31ec2733495ece3611105131d21de06c"
            ),
            LocalModelPinnedFile(
                path: "test_wavs/de.wav", byteCount: 121_388,
                sha256: "36d3c4845b9808a1656a2a2e92d884590e2db94389e6fe559643291ae0cd3710"
            )
        ]
        // A pinned constant: the catalogue URL literal always parses.
        let url = tdtV3Int8ArchiveURL!
        let archive = LocalModelPinnedArchive(
            url: url, byteCount: tdtV3Int8ArchiveByteCount, sha256: tdtV3Int8ArchiveSHA256,
            format: .tarBZip2, expandedByteCount: 671_247_872, rootDirectory: tdtV3Int8ModelName,
            directories: ["test_wavs"], files: [tokens, joiner, decoder, encoder] + testAudio
        )
        return SherpaOnnxOfflineRecognizerSpecification(
            sourceID: tdtV3Int8SourceID, displayName: tdtV3DisplayName, archive: archive,
            tokens: tokens, encoder: encoder, decoder: decoder, joiner: joiner,
            modelType: "nemo_transducer", decodingMethod: "greedy_search", featureDimension: 128,
            sampleRate: 16_000, threadCount: 2, provider: "cpu", license: tdtV3License,
            attribution: tdtV3Attribution
        )
    }()

    /// CC-BY-4.0 attribution shown wherever the model is offered and written
    /// beside every installed copy.
    static let tdtV3Attribution = """
        Parakeet TDT 0.6B v3 by NVIDIA (https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), \
        licensed under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). \
        Converted to an int8 ONNX export by the k2-fsa sherpa-onnx project \
        (https://github.com/k2-fsa/sherpa-onnx). Not endorsed by NVIDIA.
        """
}
