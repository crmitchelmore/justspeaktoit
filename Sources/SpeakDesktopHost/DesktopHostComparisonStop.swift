import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func startComparisonUpdates(generation: UUID, deadline: ContinuousClock.Instant) {
        comparisonUpdates?.cancel()
        comparisonUpdates = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, await self.isComparisonCapturing(generation) else { return }
                if ContinuousClock.now >= deadline {
                    await self.requestComparisonStop(generation: generation)
                    return
                }
                await self.refreshComparison()
            }
        }
    }

    package func requestComparisonStop(generation: UUID? = nil) {
        guard generation == nil || generation == comparisonGeneration,
              comparisonCapture != nil, comparisonFinalization == nil else { return }
        // Native events are serialized; finalization must not keep Cancel queued behind Stop.
        comparisonFinalization = Task {
            await self.stopComparison()
            self.comparisonFinalization = nil
        }
    }

    package func stopComparison() async {
        guard let active = comparisonCapture, let fanOut = comparisonLive, let comparisons else { return }
        comparisonCapture = nil
        comparisonUpdates?.cancel()
        comparisonUpdates = nil
        activeOperations += 1
        defer { finishOperation() }
        comparisonStatus("Finalizing comparison. Cancel retains audio and available raw results.")
        await refreshComparison()
        do {
            let duration = try await DesktopHostComparisonClosingCapture(active).finish()
            let entries = await fanOut.finish()
            guard let digest = Platform.comparisonDigest else {
                throw DesktopHostError(message: "Comparison SHA-256 is unavailable.")
            }
            let sample = ModelComparisonSample(
                name: active.file.url.lastPathComponent, contentHash: try digest.sha256(ofFileAt: active.file.url),
                durationSeconds: duration
            )
            guard let pending = comparisonPending else {
                throw DesktopHostError(message: "The saved microphone comparison snapshot is missing.")
            }
            let round = try DesktopComparisonRunner.completing(pending, entries: entries, sample: sample)
            try await comparisons.upsert(round)
            comparisonSelection = round.id
            comparisonStatus("Comparison saved. Review or rank the results below.")
        } catch {
            fanOut.cancel()
            comparisonStatus("Comparison recording retained: \(error.localizedDescription)")
        }
        await comparisons.endExecution(ids: comparisonOwnedRoundIDs)
        comparisonOwnedRoundIDs.removeAll()
        comparisonSync?.changed()
        busy = false
        comparisonLive = nil
        comparisonPending = nil
        await refreshComparison()
    }
}
