import Foundation
import SpeakCore
import SpeakDesktop

extension DesktopHostController {
    package func vocabularyStore() async throws -> DesktopVocabulary {
        if let task = vocabularyLoad { return try await task.value }
        let directory = directory
        let task = Task { @VocabularyActor in
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
        if kind == 4 { return try legacyPronunciationPresentation(notice: notice) }
        let vocabulary = try await vocabularyStore()
        if reload {
            do { try await vocabulary.reload() } catch {
                vocabularyLoad = nil
                throw error
            }
        }
        let status = kind == 3 ? [notice, correctionLearningStatus()].filter { !$0.isEmpty }.joined(separator: "\n")
            : notice
        return await vocabulary.presentation(kind: kind, notice: status)
    }

    package func vocabularyEvent(kind: Int, payload: String) async throws -> String {
        guard !closed else { throw CancellationError() }
        if kind == 4 { return try await legacyPronunciationEvent(payload) }
        if kind == 3, payload == "allowLearning" || payload == "stopLearning" {
            return try correctionLearningApproval(payload)
        }
        let observational = payload.split(separator: "\t", omittingEmptySubsequences: false)
        if kind == 3, let action = observational.first,
           action == "allowObservationalLearning" || action == "stopObservationalLearning" {
            guard observational.count == 2, let token = UInt64(observational[1]),
                  token > 0, String(token) == observational[1] else {
                throw DesktopHostError(message: "Observational learning requires a current local consent action.")
            }
            return try correctionLearningApproval(String(action), observationalToken: token)
        }
        let vocabulary = try await vocabularyStore()
        return try await vocabulary.perform(kind: kind, payload: payload)
    }

    package func vocabularyKeywords() async throws -> [String] {
        let vocabulary = try await vocabularyStore()
        return await vocabulary.keywords()
    }

    func recognitionVocabulary() async throws -> (keywords: [String], pronunciationWords: [String]) {
        let vocabulary = try await vocabularyStore()
        return try await vocabulary.recognitionHints()
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
        guard let text = record.correctedText ?? record.originalText else { return record }
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
