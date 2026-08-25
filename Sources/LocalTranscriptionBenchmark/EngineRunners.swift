import CTranscribe
import Foundation
import SpeakCore
import struct WhisperKit.DecodingOptions
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

protocol LocalBenchmarkEngineRunner: AnyObject {
    var engine: LocalTranscriptionEngine { get }
    var runtimeVersion: String { get }
    var runtimeCommit: String? { get }
    func transcribe(audioURL: URL, wav: WAVFile, language: String?) async throws -> String
}

final class WhisperKitBenchmarkRunner: LocalBenchmarkEngineRunner {
    let engine = LocalTranscriptionEngine.whisperKit
    // Keep in step with the argmax-oss-swift pin in Package.resolved.
    let runtimeVersion = "argmax-oss-swift 1.1.0"
    let runtimeCommit: String? = "1e2a163736dfa5a198e637ae44c114e1c6d5cc2d"
    private let pipeline: WhisperKit

    init(model: String, modelRepo: String?) async throws {
        pipeline = try await WhisperKit(WhisperKitConfig(
            model: model,
            modelRepo: modelRepo,
            verbose: false,
            load: true
        ))
    }

    func transcribe(audioURL: URL, wav: WAVFile, language: String?) async throws -> String {
        let decodeOptions = language.map { DecodingOptions(language: $0) }
        let results = try await pipeline.transcribe(
            audioPath: audioURL.path,
            decodeOptions: decodeOptions
        )
        return results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class TranscribeCppBenchmarkRunner: LocalBenchmarkEngineRunner {
    let engine = LocalTranscriptionEngine.transcribeCpp
    let runtimeVersion: String
    let runtimeCommit: String?
    private var model: OpaquePointer?
    private var session: OpaquePointer?

    init(modelPath: String, backend: String) throws {
        runtimeVersion = String(cString: transcribe_version())
        let commit = String(cString: transcribe_version_commit())
        runtimeCommit = commit == "unknown" ? nil : commit

        var modelParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&modelParams)
        switch backend.lowercased() {
        case "auto": modelParams.backend = TRANSCRIBE_BACKEND_AUTO
        case "cpu": modelParams.backend = TRANSCRIBE_BACKEND_CPU
        case "metal": modelParams.backend = TRANSCRIBE_BACKEND_METAL
        default: throw CLIError.invalidValue("--backend must be auto, cpu, or metal")
        }

        var loadedModel: OpaquePointer?
        let loadStatus = modelPath.withCString {
            transcribe_model_load_file($0, &modelParams, &loadedModel)
        }
        try Self.check(loadStatus, context: "load model")
        guard let loadedModel else { throw TranscribeCppError.nullHandle("model") }
        model = loadedModel

        var sessionParams = transcribe_session_params()
        transcribe_session_params_init(&sessionParams)
        var createdSession: OpaquePointer?
        let sessionStatus = transcribe_session_init(loadedModel, &sessionParams, &createdSession)
        do {
            try Self.check(sessionStatus, context: "create session")
            guard let createdSession else { throw TranscribeCppError.nullHandle("session") }
            session = createdSession
        } catch {
            transcribe_model_free(loadedModel)
            model = nil
            throw error
        }
    }

    deinit {
        if let session { transcribe_session_free(session) }
        if let model { transcribe_model_free(model) }
    }

    func transcribe(audioURL: URL, wav: WAVFile, language: String?) async throws -> String {
        guard let session else { throw TranscribeCppError.nullHandle("session") }
        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)

        let status: transcribe_status
        if let language, !language.isEmpty {
            status = language.withCString { languagePointer in
                runParams.language = languagePointer
                return wav.samples.withUnsafeBufferPointer {
                    transcribe_run(session, $0.baseAddress, Int32($0.count), &runParams)
                }
            }
        } else {
            status = wav.samples.withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &runParams)
            }
        }
        try Self.check(status, context: "transcribe \(audioURL.lastPathComponent)")
        return String(cString: transcribe_full_text(session))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func check(_ status: transcribe_status, context: String) throws {
        guard status == TRANSCRIBE_OK else {
            let message = String(cString: transcribe_status_string(Int32(status.rawValue)))
            throw TranscribeCppError.status("\(context): \(message) (\(status.rawValue))")
        }
    }
}

enum TranscribeCppError: Error, LocalizedError {
    case nullHandle(String)
    case status(String)

    var errorDescription: String? {
        switch self {
        case .nullHandle(let handle): return "transcribe.cpp returned a null \(handle) handle"
        case .status(let message): return message
        }
    }
}
