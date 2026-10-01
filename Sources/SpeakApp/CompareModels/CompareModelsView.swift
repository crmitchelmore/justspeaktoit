import SpeakCore
import SwiftUI

/// Settings › Compare Models (issue #1101): pick models, record or import
/// once, judge blind, then see who was who and how they score over time.
struct CompareModelsView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        CompareModelsContentView(controller: environment.compareModels)
            .onAppear { environment.compareModels.refreshCandidates() }
            .onDisappear {
                Task { await environment.compareModels.cancelStreaming() }
            }
    }
}

struct CompareModelsContentView: View {
    @ObservedObject var controller: CompareModelsController
    @ObservedObject private var localModels = LocalModelManager.shared
    @Environment(\.appVisualDensity) private var density

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = controller.errorMessage {
                    SettingsInlineInfo(
                        title: "Something went wrong", message: error, systemImage: "exclamationmark.triangle"
                    )
                }
                if controller.phase == .idle {
                    setupCards
                } else if controller.phase == .starting || controller.currentRound == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparing comparison…")
                        Button("Cancel") { Task { await controller.cancelStreaming() } }
                    }
                } else if let round = controller.currentRound {
                    CompareModelsRoundView(controller: controller, round: round)
                }
                CompareModelsScoreboardView(controller: controller)
            }
            .padding(density.isCompact ? 12 : 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: .secureAppStorageDidChange)) { _ in
            controller.refreshCandidates()
        }
        .onChange(of: localModels.installStates) { _, _ in
            controller.refreshCandidates()
        }
        .accessibilityIdentifier("compareModelsView")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compare Models").font(.title2.bold())
            Text("Send one recording to several transcription models, judge the raw transcripts blind, "
                + "and keep a scoreboard of which model works best for your voice, vocabulary and microphone. "
                + "Post-processing is never applied here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = controller.statusMessage {
                Text(status).font(.callout).foregroundStyle(Color.brandLagoon)
            }
        }
    }

    private var setupCards: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Input", systemImage: "waveform", tint: .brandLagoon) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Input", selection: $controller.mode) {
                        ForEach(ModelComparisonInputMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(modeDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsCard(title: "Models", systemImage: "rectangle.split.3x1", tint: .brandAccentWarm) {
                CompareModelsSelectionView(controller: controller)
            }
            actionRow
        }
    }

    private var modeDescription: String {
        switch controller.mode {
        case .streaming:
            return "Speak once. Every selected streaming model hears the same microphone at the same time "
                + "and its partials appear in its own column. Local models and OpenAI Realtime run in File mode only."
        case .file:
            return "Import an audio file and run it through every selected model."
        case .batch:
            return "Import several audio files. Each file becomes its own round, judged one after another."
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            switch controller.mode {
            case .streaming:
                Button {
                    Task { await controller.startStreaming() }
                } label: {
                    Label("Start listening", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canStart)
                .accessibilityIdentifier("compareModelsStart")
            case .file, .batch:
                Button {
                    Task { await controller.chooseFiles() }
                } label: {
                    Label(controller.mode == .batch ? "Choose files…" : "Choose file…", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.canStart)
                .accessibilityIdentifier("compareModelsChooseFiles")
            }
            if !controller.canStart {
                Text("Select at least two models that are ready to run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The model checklist for the current input mode, grouped by provider.
struct CompareModelsSelectionView: View {
    @ObservedObject var controller: CompareModelsController

    private var groups: [(provider: String, candidates: [ComparisonCandidate])] {
        let candidates = controller.candidatesForMode
        var order: [String] = []
        var grouped: [String: [ComparisonCandidate]] = [:]
        for candidate in candidates {
            if grouped[candidate.providerDisplayName] == nil { order.append(candidate.providerDisplayName) }
            grouped[candidate.providerDisplayName, default: []].append(candidate)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Select all ready") { controller.selectAllUsable() }
                Button("Select none") { controller.selectedModelIDs = [] }
                Spacer()
                Text("\(controller.selectedUsableCandidates.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            ForEach(groups, id: \.provider) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.provider).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(group.candidates) { candidate in
                        row(for: candidate)
                    }
                }
            }
            Text("Only models that can run right now are selectable: cloud models with a saved API key, "
                + "downloaded local models, and Apple's on-device transcribers.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(for candidate: ComparisonCandidate) -> some View {
        Toggle(isOn: Binding(
            get: { controller.selectedModelIDs.contains(candidate.modelID) && candidate.isUsable },
            set: { _ in controller.toggle(candidate) }
        )) {
            HStack(spacing: 6) {
                Text(candidate.displayName)
                if let reason = candidate.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let price = TranscriptionPricing.pricePerMinuteUSD(modelID: candidate.modelID), price > 0 {
                    Text("~\(TranscriptionPricing.formatted(price))/min")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!candidate.isUsable)
        .accessibilityIdentifier("compareModelsCandidate-\(candidate.modelID)")
    }
}
