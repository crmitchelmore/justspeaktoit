import Foundation
import SpeakCore
import SpeakDesktop

// Local models' rows and runtime line, and the picker labels that follow them.
extension DesktopHostLocalModelHost where Platform: DesktopHostLocalModelPlatform {
    /// The runtime line shown in Local models.
    package var localRuntimeStatus: String {
        let notice = localModels.importStatus.map { " " + $0 } ?? ""
        return localRuntimeSummary + notice
    }

    private var localRuntimeSummary: String {
        let models = localModelSpecs
        let installer = localInstaller
        let downloaded = models.filter { installer.state(of: .init($0)) == .installed }.count
        let counts = "\(downloaded) of \(models.count) on-device models downloaded."
        if let failure = localModels.runtimeFailure { return failure + " " + counts }
        guard Platform.localRuntimeMissing == nil else {
            return "The on-device speech runtime (whisper.cpp) is not included in this build. " + counts
        }
        if let runtime = localModels.runtime { return "On-device: \(runtime.description). " + counts }
        return Platform.localRuntimeSummary(useGPU: localUseGPU) + " " + counts
    }

    /// Presents every row, and refreshes the picker when a model's state label changed.
    package func publishLocalModels() {
        guard !closed, localModels.presenting else { return }
        let installer = localInstaller
        var labels: [String: String] = [:]
        var rows: [DesktopHostLocalModelRow] = []
        for spec in localModelSpecs {
            let (row, label) = localModelRow(spec, installer: installer)
            rows.append(row)
            labels[spec.catalogueID] = label
            // A live model shares its batch model's download.
            let live = DesktopLocalStreaming.liveModelID(for: spec)
            if DesktopHostModels.isLocalLive(live) { labels[live] = label }
        }
        if labels != DesktopHostModels.labelledSnapshot.1 {
            DesktopHostModels.setLocalLabels(labels)
            refreshModelPicker()
        }
        Platform.presentLocalModels(
            rows, status: localRuntimeStatus, useGPU: localUseGPU, presenter: localModels.presenter
        )
    }

    /// One model's row in Local models, and the state shown after its name in
    /// the model picker unless it is simply downloaded.
    private func localModelRow(
        _ spec: WhisperCppModel, installer: LocalModelInstaller
    ) -> (row: DesktopHostLocalModelRow, label: String?) {
        let size = Self.megabytes(spec.artifact.byteCount)
        let state: DesktopHostLocalModelRow.State
        let detail: String
        var label: String?
        if let received = localModels.progress[spec.catalogueID], localModels.downloads[spec.catalogueID] != nil {
            state = .downloading
            detail = "Downloading \(received * 100 / max(spec.artifact.byteCount, 1))% of \(size)"
            label = "downloading"
        } else if localModels.ownership.isRemoving(spec.catalogueID) {
            state = .removing
            detail = "\(size) \u{00B7} Removing\u{2026}"
            label = "removing"
        } else {
            switch installer.state(of: .init(spec)) {
            case .installed:
                state = .downloaded
                detail = "\(size) \u{00B7} Downloaded and verified"
            case .partial(let received, let total):
                state = .paused
                detail = "\(size) \u{00B7} \(received * 100 / max(total, 1))% downloaded, paused"
                label = "download paused"
            case .notInstalled:
                state = .notDownloaded
                detail = "\(size) \u{00B7} Not downloaded"
                label = "download in Local models"
            }
        }
        let about = "\(spec.summary) Whisper weights (\(spec.quantization), \(spec.artifact.license) licence) "
            + "from \(spec.artifact.provenance), pinned by SHA-256 "
            + "\(spec.artifact.sha256.prefix(12))\u{2026} and verified after download."
        return (DesktopHostLocalModelRow(name: spec.displayName, detail: detail, about: about, state: state), label)
    }

    package static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_048_576).rounded())) MB"
    }
}
