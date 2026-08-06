import SpeakCore
import Foundation

// MARK: - Post-processing helpers (extracted from MainManager 1474-line God class)

extension MainManager {
    func shouldRunPostProcessing() -> Bool {
        let shouldSkipForLivePolish = appSettings.speedMode.usesLivePolish
            && appSettings.skipPostProcessingWithLivePolish
        guard !shouldSkipForLivePolish else { return false }
        let hasAssemblyAIPrompt = false && appSettings.liveTranscriptionModel.contains("assemblyai")
        return appSettings.postProcessingEnabled || hasAssemblyAIPrompt
    }

    func postProcessingRequestPreview(systemPrompt: String, rawText: String) -> String {
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let promptSection = trimmedPrompt.isEmpty ? "<default prompt>" : trimmedPrompt
        let truncatedRaw = rawText.prefix(600)
        return "System Prompt:\n\(promptSection)\n\nUser Text:\n\(truncatedRaw)"
    }

    static func friendlyPostProcessingMessage(for error: Error, modelIdentifier: String) -> String {
        let trimmedModel = modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = ModelCatalog.friendlyName(
            for: trimmedModel.isEmpty ? "inception/mercury" : trimmedModel
        )
        if let routerError = error as? OpenRouterClientError {
            switch routerError {
            case .apiKeyMissing:
                // swiftlint:disable:next line_length
                return "Post-processing skipped because no OpenRouter API key is configured. Add one in Settings › API Keys."
            case .invalidResponse:
                return "OpenRouter returned an unexpected response while using \(displayName)."
            case .httpStatus(let code, let body):
                if let detail = parseOpenRouterMessage(from: body) {
                    return "OpenRouter rejected \(displayName) (status \(code)): \(detail)"
                }
                return "OpenRouter responded with status \(code) while using \(displayName)."
            case .audioFileTooLarge:
                return routerError.localizedDescription
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Network error while contacting OpenRouter: \(nsError.localizedDescription)."
        }
        return error.localizedDescription
    }

    static func parseOpenRouterMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorDict = json["error"] as? [String: Any], let message = errorDict["message"] as? String {
                return message
            }
            if let message = json["message"] as? String { return message }
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 200 { return String(trimmed.prefix(200)) + "…" }
        return trimmed
    }

    func makeLexiconContext(for text: String, destination: String?) -> PersonalLexiconContext {
        var tags: Set<String> = []
        let lowered = text.lowercased()
        if lowered.contains("dear ") || lowered.contains("regards") || lowered.contains("sincerely") {
            tags.insert("formal")
        }
        if lowered.contains("meeting") || lowered.contains("agenda")
            || lowered.contains("project") || lowered.contains("quarterly") {
            tags.insert("work")
        }
        if lowered.contains("love") || lowered.contains("babe") || lowered.contains("sweetheart") {
            tags.insert("intimate")
        }
        if let destination, !destination.isEmpty {
            let lowerDest = destination.lowercased()
            if lowerDest.contains("mail") || lowerDest.contains("outlook") { tags.insert("formal") }
            if lowerDest.contains("messages") || lowerDest.contains("imessage") { tags.insert("casual") }
            if lowerDest.contains("slack") || lowerDest.contains("teams") { tags.insert("work") }
        }
        let window = String(text.suffix(400))
        return PersonalLexiconContext(tags: tags, destinationApplication: destination, recentTranscriptWindow: window)
    }
}
