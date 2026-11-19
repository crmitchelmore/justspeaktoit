import Foundation
import SpeakCore

extension DesktopHostController {
    func comparisonExportEvent(_ event: Int32, text: String, index: Int32) async {
        do {
            try admitComparisonExport()
            guard index == 0 || index == 1, let comparisons else {
                throw DesktopHostError(message: "Choose JSON or Markdown from an open comparison.")
            }
            var identifier = event == 126 ? text : ""
            var path = text
            if event == 127 {
                guard let separator = text.firstIndex(of: "\n") else {
                    throw DesktopHostError(message: "Select a saved comparison and export destination.")
                }
                identifier = String(text[..<separator])
                path = String(text[text.index(after: separator)...])
            }
            var rounds = await comparisons.rounds()
            try admitComparisonExport()
            if event == 127 || !identifier.isEmpty {
                guard let id = UUID(uuidString: identifier), let round = rounds.first(where: { $0.id == id }) else {
                    throw DesktopHostError(message: "The selected comparison is no longer available.")
                }
                rounds = [round]
            }
            guard !rounds.isEmpty else {
                throw DesktopHostError(message: "There are no saved comparisons to export.")
            }
            let data = try index == 1 ? Data(ModelComparisonExport.markdown(rounds: rounds).utf8)
                : ModelComparisonExport.json(rounds: rounds)
            if event == 126 {
                try copyComparisonExport(data)
            } else {
                guard !path.isEmpty else {
                    throw DesktopHostError(message: "Choose a destination for the comparison export.")
                }
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                comparisonStatus("Comparison export saved. It includes model identities and transcripts, never audio.")
            }
        } catch { comparisonStatus("Comparison export failed: \(error.localizedDescription)") }
    }

    private func admitComparisonExport() throws {
        guard !closed, !busy else {
            throw DesktopHostError(message: "Finish or cancel the comparison before exporting its results.")
        }
    }

    private func copyComparisonExport(_ data: Data) throws {
        guard let content = String(data: data, encoding: .utf8) else {
            throw DesktopHostError(message: "The comparison export could not be encoded as text.")
        }
        guard !content.contains("\0") else {
            throw DesktopHostError(message: "This export contains a null character. Save it to a file instead.")
        }
        try Platform.copyToClipboard(content)
        comparisonStatus("Comparison export copied. It includes model identities and transcripts, never audio.")
    }
}
