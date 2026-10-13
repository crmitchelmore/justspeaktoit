import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func vocabularyStore() async throws -> DesktopVocabulary {
        if let task = vocabularyLoad { return try await task.value }
        let directory = directory
        let task = Task { @MainActor in
            let vocabulary = DesktopVocabulary(directory: directory)
            try await vocabulary.load()
            return vocabulary
        }
        vocabularyLoad = task
        do {
            return try await task.value
        } catch {
            vocabularyLoad = nil
            throw error
        }
    }

    package func vocabularyPresentation(kind: Int, notice: String = "", reload: Bool = false) async throws -> String {
        let vocabulary = try await vocabularyStore()
        if reload {
            do { try await vocabulary.reload() } catch {
                vocabularyLoad = nil
                throw error
            }
        }
        return await vocabulary.presentation(kind: kind, notice: notice)
    }

    package func vocabularyEvent(kind: Int, payload: String) async throws -> String {
        guard !closed else { throw CancellationError() }
        let vocabulary = try await vocabularyStore()
        return try await vocabulary.perform(kind: kind, payload: payload)
    }

    package func vocabularyKeywords() async throws -> [String] {
        let vocabulary = try await vocabularyStore()
        return await vocabulary.keywords()
    }

    package func vocabularyHistoryPresentation(_ identifier: String) throws -> String {
        guard canUseHistory, let id = UUID(uuidString: identifier), selectedHistoryID == id,
              let record = history[id], isVisible(id) else {
            throw DesktopHostError(message: "Select a visible saved recording to inspect its correction results.")
        }
        return "Recording: " + DateFormatter.localizedString(
            from: record.createdAt, dateStyle: .medium, timeStyle: .short
        )
            + "\n\n" + DesktopVocabularyHistory.details(record.lexiconSummary)
    }

    func applyVocabulary(_ original: DesktopRecordingStore.Record) async throws -> DesktopRecordingStore.Record {
        var record = original
        guard let text = record.originalText else { return record }
        let vocabulary = try await vocabularyStore()
        let application = await vocabulary.apply(text)
        record.correctedText = application.result.transformedText
        record.lexiconSummary = application.summary
        record.lexiconDirectives = application.directives
        record.lexiconContextTags = await vocabulary.preferences.includeContextTags
            ? application.summary.contextTags : []
        return record
    }
}
