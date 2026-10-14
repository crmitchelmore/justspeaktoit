import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopVoiceUsagePresentation: Sendable {
    package let requestID: String
    package let text: String
    package let trackingEnabled: Bool
}

package struct DesktopVoiceUsageState: Sendable {
    package var records: [VoiceSynthesisUsage.Record]?
    package var loadFailed = false
    package var warning: String?
    package var epoch = UUID()
    package var requestID: String?
    package var estimate = "Open Usage again to capture a fresh text/voice estimate."
}

package struct DesktopVoiceUsageOperation: Sendable {
    package let capture: VoiceSynthesisUsage.Capture
    package let epoch: UUID
}

extension DesktopHostController where Platform: DesktopHostReadAloudPlatform {
    package var voiceUsageTrackingEnabled: Bool {
        voiceOutputSettings().trackUsage ?? VoiceUsagePolicy.defaultTrackingEnabled
    }

    package func beginVoiceUsage(
        operation: VoiceSynthesisUsage.Operation, source: VoiceOutputSource, recordID: UUID?
    ) -> DesktopVoiceUsageOperation? {
        guard voiceUsageTrackingEnabled else { return nil }
        return .init(capture: .init(operation: operation, source: source, historyRecordID: recordID),
                     epoch: voiceUsage.epoch)
    }

    package func finishVoiceUsage(_ operation: DesktopVoiceUsageOperation?) {
        guard let operation, operation.epoch == voiceUsage.epoch, voiceUsageTrackingEnabled else { return }
        let requests = operation.capture.records
        guard !requests.isEmpty else { return }
        loadVoiceUsage()
        guard !voiceUsage.loadFailed else {
            presentVoiceUsage()
            if !closed, let warning = voiceUsage.warning { update(warning) }
            return
        }
        voiceUsage.records = Array(((voiceUsage.records ?? []) + requests)
            .suffix(VoiceUsagePolicy.maximumRetainedRequests))
        do {
            let folder = directory.appendingPathComponent("VoiceUsage")
            try Platform.preparePrivateDirectory(folder)
            try JSONEncoder().encode(voiceUsage.records ?? []).write(
                to: folder.appendingPathComponent("requests.json"), options: .atomic
            )
            voiceUsage.warning = nil
        } catch {
            voiceUsage.warning = "Usage is only in memory: the local ledger could not be saved. "
                + error.localizedDescription
        }
        presentVoiceUsage()
        if !closed, let warning = voiceUsage.warning { update(warning) }
    }

    package func showVoiceUsage(text: String, requestID: String) {
        guard !closed else { return }
        voiceUsage.requestID = requestID
        let count = text.unicodeScalars.count
        do {
            let selection = try currentVoiceSelection()
            let estimate = VoiceSynthesisPricing.estimate(
                for: selection.voice, characterCount: count, xaiInventory: selection.xaiInventory)
            voiceUsage.estimate = "Captured text: \(count) input characters (Unicode scalars).\n"
                + "Voice: \(selection.voice.label)\n"
                + (estimate.map { "Input estimate: USD \(Self.voiceCost($0))." }
                    ?? "Input estimate: unknown; no published rate for this model.")
                + (selection.options.useSSML ? "\nSSML is enabled; markup may be billed differently." : "")
        } catch {
            voiceUsage.estimate = "Input estimate unavailable: \(error.localizedDescription)"
        }
        loadVoiceUsage()
        presentVoiceUsage()
    }

    package func saveVoiceUsageTracking(_ enabled: Bool, requestID: String) {
        guard !closed else { return }
        var changed = voiceOutputSettings()
        changed.trackUsage = enabled
        let message = enabled ? "Local Voice usage tracking enabled."
            : "Local Voice usage tracking disabled. Earlier usage is retained."
        if !persistVoiceOutput(changed, message: message) {
            voiceUsage.warning = "The tracking preference could not be saved; the previous setting is unchanged."
        }
        voiceUsage.requestID = requestID
        presentVoiceUsage()
    }

    private func loadVoiceUsage() {
        guard voiceUsage.records == nil, !voiceUsage.loadFailed else { return }
        let url = directory.appendingPathComponent("VoiceUsage/requests.json")
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { voiceUsage.records = []; return }
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.intValue <= 2 * 1_024 * 1_024 else {
                throw DesktopHostError(message: "The usage ledger exceeds its size limit.")
            }
            let records = try JSONDecoder().decode([VoiceSynthesisUsage.Record].self, from: Data(contentsOf: url))
            guard records.count <= VoiceUsagePolicy.maximumRetainedRequests,
                  records.allSatisfy({ $0.inputCharacters >= 0 && $0.inputCharacters <= 100_000 &&
                      ($0.audioDuration.map { $0.isFinite && $0 >= 0 } ?? true) }) else {
                throw DesktopHostError(message: "The usage ledger contains invalid measurements.")
            }
            voiceUsage.records = records
        } catch {
            voiceUsage.loadFailed = true
            voiceUsage.warning = "Usage accounting unavailable; the existing ledger is unchanged. "
                + error.localizedDescription
        }
    }

    private func presentVoiceUsage() {
        guard !closed, let requestID = voiceUsage.requestID else { return }
        Platform.voiceUsage(.init(requestID: requestID, text: voiceUsageSummary(),
                                  trackingEnabled: voiceUsageTrackingEnabled))
    }

    package func voiceUsageSummary() -> String {
        let records = voiceUsage.records ?? []
        let completed = records.filter { $0.outcome == .completed }
        let unpriced = completed.filter { $0.estimatedCostUSD == nil }.count
        let cost = completed.compactMap(\.estimatedCostUSD).reduce(Decimal.zero, +)
        let duration = completed.compactMap(\.audioDuration).reduce(0, +)
        var lines = [
            voiceUsage.estimate,
            "Estimates are not charges. No provider billing receipts or token counts are available.",
            "Local requests retained: \(records.count) (latest \(VoiceUsagePolicy.maximumRetainedRequests)).",
            "Validated audio: \(completed.count) requests; failed: \(records.filter { $0.outcome == .failed }.count); "
                + "cancelled: \(records.filter { $0.outcome == .cancelled }.count).",
            "Validated audio: \(String(format: "%.2f", duration)) seconds; "
                + "\(completed.reduce(0) { $0 + $1.inputCharacters }) input characters.",
            "Known-price estimate for validated audio: USD \(Self.voiceCost(cost)). "
                + "Unpriced requests excluded: \(unpriced).",
            "Transport attempts do not prove server receipt. Failed/cancelled requests may still be billed.",
            "Active work is accounted when its owned operation ends; "
                + "forced termination can lose in-flight observations.",
            "SSML, provider character rules, discounts and regional rates can change actual charges.",
            voiceUsageTrackingEnabled ? "Tracking on: only text-free local metadata is kept."
                : "Tracking off: new requests are not recorded; earlier local usage is retained."
        ]
        if let last = records.last {
            lines.append("Last request: \(last.modelID) / \(last.voiceID), \(last.operation.rawValue), "
                + "\(last.source.displayName), \(last.outcome.rawValue), \(last.inputCharacters) input characters.")
            lines.append("History owner: \(last.historyRecordID?.uuidString ?? "none (not a History source)").")
        }
        if let warning = voiceUsage.warning { lines.append(warning) }
        return lines.joined(separator: "\n\n")
    }

    private static func voiceCost(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
