import Foundation
import SpeakCore

extension DesktopHostController {
    func comparisonPreferenceEvent(_ event: Int32, text: String, live: Bool) async {
        guard !closed, let comparisons else { return }
        if event == 124 {
            let rounds = await comparisons.rounds()
            guard let round = rounds.first(where: { $0.id == comparisonSelection }),
                  let id = UUID(uuidString: text), round.entries.contains(where: { $0.id == id }) else {
                comparisonStatus("The comparison reference is no longer available.")
                return
            }
            comparisonReference = id
            return
        }
        guard !busy else { return }
        let available = Set(comparisonModelStates().filter {
            DesktopHostModels.isLive($0.option.id) == live && $0.unavailableReason == nil
        }.map(\.option.id))
        do {
            let selected = Set(text.split(separator: "\t").map(String.init))
            try await comparisons.selectModels(selected, replacing: available)
        } catch {
            comparisonStatus("Comparison model selection was not saved: \(error.localizedDescription)")
        }
    }
}

actor DesktopComparisonWordPresentation {
    private struct CachedDiff {
        let reference: String
        let candidate: String
        let result: String
    }
    private var cache: [UUID: CachedDiff] = [:]

    func diff(reference: String, candidate: String, id: UUID) async -> String {
        if let previous = cache[id], previous.reference == reference, previous.candidate == candidate {
            return previous.result
        }
        let result = await Task.detached {
            TranscriptWordDiff.diff(reference: reference, candidate: candidate).map {
                switch $0.kind {
                case .equal: $0.text
                case .inserted: "[+\($0.text)]"
                case .deleted: "[-\($0.text)]"
                }
            }.joined(separator: " ")
        }.value
        if cache.count >= 8, cache[id] == nil { cache.removeAll() }
        cache[id] = CachedDiff(reference: reference, candidate: candidate, result: result)
        return result
    }
}
