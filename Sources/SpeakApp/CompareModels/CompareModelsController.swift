import AppKit
import AVFoundation
import Foundation
import SpeakCore
import SwiftUI

/// Drives the Compare Models section: model selection, the three input
/// modes, blind judging, reveal, the scoreboard and export (issue #1101).
///
/// File-mode runs live in `CompareModelsController+Files.swift`; export and
/// the capture bookkeeping in `CompareModelsController+Support.swift`.
@MainActor
final class CompareModelsController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case streaming
        case transcribing
        case judging
        case revealed
    }

    @Published var phase: Phase = .idle
    @Published var mode: ModelComparisonInputMode = .streaming {
        didSet { if mode != oldValue { refreshCandidates() } }
    }
    @Published private(set) var candidates: [ComparisonCandidate] = []
    @Published var selectedModelIDs: Set<String> {
        didSet { defaults.set(Array(selectedModelIDs).sorted(), forKey: Self.selectionDefaultsKey) }
    }
    /// The round being run or judged. Persisted once judged.
    @Published var currentRound: ModelComparisonRound?
    /// Live transcript per entry while streaming or transcribing.
    @Published var liveTranscripts: [UUID: String] = [:]
    @Published var pendingRanks: [UUID: Int] = [:]
    /// The blind column other transcripts are diffed against.
    @Published var referenceEntryID: UUID?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// Files still to run as consecutive batch rounds.
    @Published var queuedFiles: [URL] = []
    @Published var isDictationBusy = false

    let store: ComparisonRoundStore
    /// The environment owns this controller for the app's lifetime (see
    /// `AppEnvironment.compareModels`), so the back-reference is unowned.
    unowned let environment: AppEnvironment
    let fanOut: ComparisonLiveFanOut
    let fileRunner: ComparisonFileRunner
    private let defaults: UserDefaults
    var captureOwnershipHeld = false
    var runID = UUID()
    var fileTask: Task<[ModelComparisonEntry], Never>?
    var captureLimitTask: Task<Void, Never>?

    static let selectionDefaultsKey = "compareModels.selectedModelIDs"

    init(environment: AppEnvironment, store: ComparisonRoundStore, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.store = store
        self.defaults = defaults
        fanOut = ComparisonLiveFanOut(
            permissionsManager: environment.permissions,
            audioDeviceManager: environment.audioDevices,
            secureStorage: environment.secureStorage,
            appSettings: environment.settings
        )
        fileRunner = ComparisonFileRunner(secureStorage: environment.secureStorage, openRouter: environment.openRouter)
        selectedModelIDs = Set(defaults.stringArray(forKey: Self.selectionDefaultsKey) ?? [])
        refreshCandidates()
    }

    var rounds: [ModelComparisonRound] { store.rounds }
    var scoreboard: [ModelComparisonScore] { ModelComparisonScoreboard.scores(for: store.rounds) }

    var candidatesForMode: [ComparisonCandidate] {
        candidates.filter { $0.supports(mode) }
    }

    var selectedUsableCandidates: [ComparisonCandidate] {
        candidatesForMode.filter { selectedModelIDs.contains($0.modelID) && $0.isUsable }
    }

    var canStart: Bool {
        phase == .idle && selectedUsableCandidates.count >= 2
    }

    var isRankingComplete: Bool {
        guard let round = currentRound else { return false }
        return ModelComparisonRound.isCompleteRanking(
            pendingRanks.map { ModelComparisonRanking(entryID: $0.key, rank: $0.value) },
            for: round.entries
        )
    }

    // MARK: Candidates

    func refreshCandidates() {
        let localModels = LocalModelManager.shared
        let environment = ComparisonCandidateResolver.Environment(
            storedAPIKeyIdentifiers: Set(self.environment.settings.trackedAPIKeyIdentifiers),
            installedLocalModelIDs: Set(localModels.availableModels.map(\.id).filter { localModels.isInstalled($0) }),
            azureEndpointConfigured: !ComparisonLiveFanOut.configuredAzureEndpoint.isEmpty,
            supportsSpeechTranscriber: AppleLocalModels.supportsSpeechTranscriber,
            supportsDictationTranscriber: AppleLocalModels.supportsDictationTranscriber
        )
        candidates = ComparisonCandidateResolver.candidates(in: environment)
    }

    func toggle(_ candidate: ComparisonCandidate) {
        if selectedModelIDs.contains(candidate.modelID) {
            selectedModelIDs.remove(candidate.modelID)
        } else {
            selectedModelIDs.insert(candidate.modelID)
        }
    }

    func selectAllUsable() {
        selectedModelIDs.formUnion(candidatesForMode.filter(\.isUsable).map(\.modelID))
    }

    // MARK: Streaming

    func startStreaming() async {
        guard canStart, mode == .streaming else { return }
        guard reserveCapture() else { return }
        let generation = UUID()
        runID = generation
        phase = .starting
        errorMessage = nil
        liveTranscripts = [:]
        let selection = selectedUsableCandidates
        do {
            let entries = try await fanOut.start(
                candidates: selection,
                language: environment.settings.preferredModelLanguage,
                localeIdentifier: environment.settings.resolvedPreferredLocaleIdentifier
            ) { [weak self] update in
                guard self?.runID == generation else { return }
                self?.liveTranscripts[update.entryID] = update.text
            }
            guard runID == generation else { return }
            currentRound = makeRound(entries: entries, mode: .streaming, sample: ModelComparisonSample(
                name: Self.captureName(), contentHash: nil, durationSeconds: 0
            ))
            phase = .streaming
            captureLimitTask = Task { [weak self] in
                guard (try? await Task.sleep(for: .seconds(600))) != nil else { return }
                self?.captureLimitTask = nil
                await self?.stopStreaming()
            }
            statusMessage = "Listening… speak, then press Stop."
        } catch {
            guard runID == generation else { return }
            await fanOut.cancel()
            releaseCapture()
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    func stopStreaming() async {
        guard phase == .streaming, let round = currentRound else { return }
        let generation = runID
        captureLimitTask?.cancel()
        captureLimitTask = nil
        phase = .transcribing
        statusMessage = "Waiting for final transcripts…"
        let outcome = await fanOut.stop()
        guard runID == generation else { return }
        releaseCapture()
        let sample = ModelComparisonSample(
            name: round.sample.name,
            contentHash: outcome.contentHash,
            durationSeconds: outcome.durationSeconds
        )
        do {
            try saveCapture(outcome.pcm16, named: round.sample.name)
        } catch {
            errorMessage = "The recording could not be saved: \(error.localizedDescription)"
        }
        beginJudging(ModelComparisonRound(
            id: round.id,
            createdAt: round.createdAt,
            inputMode: .streaming,
            sample: sample,
            language: round.language,
            originPlatform: round.originPlatform,
            entries: outcome.entries,
            blindOrder: round.blindOrder
        ))
    }

    func cancelStreaming() async {
        guard phase == .streaming || phase == .starting || phase == .transcribing else { return }
        runID = UUID()
        fileTask?.cancel()
        fileTask = nil
        captureLimitTask?.cancel()
        captureLimitTask = nil
        await fanOut.cancel()
        releaseCapture()
        queuedFiles = []
        currentRound = nil
        liveTranscripts = [:]
        phase = .idle
        statusMessage = nil
    }

    // MARK: Judging

    func beginJudging(_ round: ModelComparisonRound) {
        currentRound = round
        liveTranscripts = Dictionary(uniqueKeysWithValues: round.entries.map { ($0.id, $0.transcript) })
        pendingRanks = [:]
        referenceEntryID = round.entriesInBlindOrder.first(where: { !$0.didFail })?.id
        let usable = round.entries.filter { !$0.didFail }.count
        if usable < 2 {
            // Nothing to judge; store the evidence and reveal straight away.
            store.upsert(round)
            phase = .revealed
            statusMessage = usable == 0 ? "No model produced a transcript." : "Only one model produced a transcript."
        } else {
            phase = .judging
            statusMessage = "Rank the transcripts from best (1) to worst, then submit."
        }
    }

    func setRank(_ rank: Int?, for entryID: UUID) {
        if let rank {
            // A rank is unique: taking it from another entry keeps the
            // ranking a permutation.
            for (otherID, otherRank) in pendingRanks where otherRank == rank && otherID != entryID {
                pendingRanks[otherID] = nil
            }
            pendingRanks[entryID] = rank
        } else {
            pendingRanks[entryID] = nil
        }
    }

    func submitRanking() {
        guard var round = currentRound, isRankingComplete else { return }
        let rankings = pendingRanks.map { ModelComparisonRanking(entryID: $0.key, rank: $0.value) }
        guard round.judge(rankings: rankings) else { return }
        guard store.upsert(round) else {
            errorMessage = store.persistenceError ?? "Could not save the ranking. Please try again."
            return
        }
        currentRound = round
        phase = .revealed
        statusMessage = "Ranking saved. Model names revealed."
    }

    /// Clears the finished round. In batch mode the next queued file starts.
    func finishRound() async {
        currentRound = nil
        liveTranscripts = [:]
        pendingRanks = [:]
        phase = .idle
        statusMessage = nil
        if !queuedFiles.isEmpty {
            let next = queuedFiles.removeFirst()
            await runFile(next)
        }
    }

    func discardRound() async {
        if let round = currentRound, round.isJudged == false, store.round(id: round.id) != nil {
            store.remove(id: round.id)
        }
        if let round = currentRound, store.round(id: round.id) == nil {
            store.discardSample(for: round)
        }
        queuedFiles = []
        await finishRound()
    }

    func deleteRound(id: UUID) {
        store.remove(id: id)
    }
}
