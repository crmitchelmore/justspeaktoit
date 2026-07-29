import Foundation
import SpeakCore

public struct LocalTranscriptionBenchmarkCorpus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let cases: [LocalTranscriptionBenchmarkCase]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        cases: [LocalTranscriptionBenchmarkCase]
    ) {
        self.schemaVersion = schemaVersion
        self.cases = cases
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw LocalTranscriptionBenchmarkError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !cases.isEmpty else {
            throw LocalTranscriptionBenchmarkError.emptyCorpus
        }
        let identifiers = cases.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw LocalTranscriptionBenchmarkError.duplicateCaseIdentifiers
        }
        guard cases.allSatisfy({ !$0.id.isEmpty && !$0.audioPath.isEmpty }) else {
            throw LocalTranscriptionBenchmarkError.invalidCase
        }
    }
}

public struct LocalTranscriptionBenchmarkCase: Codable, Equatable, Sendable {
    public let id: String
    public let audioPath: String
    public let referenceTranscript: String
    public let language: String?
    public let tags: [String]

    public init(
        id: String,
        audioPath: String,
        referenceTranscript: String,
        language: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.audioPath = audioPath
        self.referenceTranscript = referenceTranscript
        self.language = language
        self.tags = tags
    }
}

public struct LocalTranscriptionBenchmarkReport: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let engine: LocalTranscriptionEngine
    public let runtimeVersion: String
    public let runtimeCommit: String?
    public let model: String
    public let modelSource: String?
    public let generatedAt: Date
    public let host: LocalTranscriptionBenchmarkHost
    public let coldLoadSeconds: Double
    public let warmupIterations: Int
    public let measuredIterations: Int
    public let measurements: [LocalTranscriptionBenchmarkMeasurement]
    public let failures: [LocalTranscriptionBenchmarkFailure]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        engine: LocalTranscriptionEngine,
        runtimeVersion: String,
        runtimeCommit: String? = nil,
        model: String,
        modelSource: String? = nil,
        generatedAt: Date = Date(),
        host: LocalTranscriptionBenchmarkHost,
        coldLoadSeconds: Double,
        warmupIterations: Int,
        measuredIterations: Int,
        measurements: [LocalTranscriptionBenchmarkMeasurement],
        failures: [LocalTranscriptionBenchmarkFailure]
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.runtimeVersion = runtimeVersion
        self.runtimeCommit = runtimeCommit
        self.model = model
        self.modelSource = modelSource
        self.generatedAt = generatedAt
        self.host = host
        self.coldLoadSeconds = coldLoadSeconds
        self.warmupIterations = warmupIterations
        self.measuredIterations = measuredIterations
        self.measurements = measurements
        self.failures = failures
    }

    public var summary: LocalTranscriptionBenchmarkSummary {
        LocalTranscriptionBenchmarkSummary(report: self)
    }
}

public struct LocalTranscriptionBenchmarkHost: Codable, Equatable, Sendable {
    public let hardwareModel: String
    public let processor: String
    public let operatingSystem: String
    public let architecture: String
    public let physicalMemoryBytes: UInt64

    public init(
        hardwareModel: String,
        processor: String,
        operatingSystem: String,
        architecture: String,
        physicalMemoryBytes: UInt64
    ) {
        self.hardwareModel = hardwareModel
        self.processor = processor
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public struct LocalTranscriptionBenchmarkMeasurement: Codable, Equatable, Sendable {
    public let caseID: String
    public let iteration: Int
    public let tags: [String]
    public let language: String?
    public let referenceTranscript: String
    public let transcript: String
    public let audioSeconds: Double
    public let wallSeconds: Double
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let peakResidentMemoryMB: Double

    public init(
        caseID: String,
        iteration: Int,
        tags: [String],
        language: String? = nil,
        referenceTranscript: String,
        transcript: String,
        audioSeconds: Double,
        wallSeconds: Double,
        userCPUSeconds: Double,
        systemCPUSeconds: Double,
        peakResidentMemoryMB: Double
    ) {
        self.caseID = caseID
        self.iteration = iteration
        self.tags = tags
        self.language = language
        self.referenceTranscript = referenceTranscript
        self.transcript = transcript
        self.audioSeconds = audioSeconds
        self.wallSeconds = wallSeconds
        self.userCPUSeconds = userCPUSeconds
        self.systemCPUSeconds = systemCPUSeconds
        self.peakResidentMemoryMB = peakResidentMemoryMB
    }

    public var realTimeFactor: Double {
        guard audioSeconds > 0 else { return 0 }
        return wallSeconds / audioSeconds
    }

    public var wordErrorRate: Double {
        TranscriptErrorRate.wordErrorRate(
            reference: referenceTranscript,
            hypothesis: transcript,
            language: language
        )
    }

    public var characterErrorRate: Double {
        TranscriptErrorRate.characterErrorRate(reference: referenceTranscript, hypothesis: transcript)
    }
}

public struct LocalTranscriptionBenchmarkFailure: Codable, Equatable, Sendable {
    public let caseID: String
    public let iteration: Int
    public let message: String

    public init(caseID: String, iteration: Int, message: String) {
        self.caseID = caseID
        self.iteration = iteration
        self.message = message
    }
}

public struct LocalTranscriptionBenchmarkSummary: Codable, Equatable, Sendable {
    public let wordErrorRate: Double
    public let characterErrorRate: Double
    public let medianWallSeconds: Double
    public let medianRealTimeFactor: Double
    public let peakResidentMemoryMB: Double
    public let failureCount: Int
    public let caseCount: Int
    public let tagCoverage: [String]

    public init(report: LocalTranscriptionBenchmarkReport) {
        wordErrorRate = TranscriptErrorRate.aggregateWordErrorRate(report.measurements)
        characterErrorRate = TranscriptErrorRate.aggregateCharacterErrorRate(report.measurements)
        medianWallSeconds = Self.median(report.measurements.map(\.wallSeconds))
        medianRealTimeFactor = Self.median(report.measurements.map(\.realTimeFactor))
        peakResidentMemoryMB = report.measurements.map(\.peakResidentMemoryMB).max() ?? 0
        failureCount = report.failures.count
        caseCount = Set(report.measurements.map(\.caseID)).count
        tagCoverage = Array(Set(report.measurements.flatMap(\.tags))).sorted()
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            return (sorted[(sorted.count / 2) - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
    }
}

public enum LocalTranscriptionBenchmarkError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case emptyCorpus
    case duplicateCaseIdentifiers
    case invalidCase

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "Unsupported benchmark schema version: \(version)"
        case .emptyCorpus:
            return "The benchmark corpus has no cases."
        case .duplicateCaseIdentifiers:
            return "Benchmark case identifiers must be unique."
        case .invalidCase:
            return "Every benchmark case needs a non-empty id and audioPath."
        }
    }
}
