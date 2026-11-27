import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension VoiceStudioAPI {
    // MARK: - JSON Parsing

    static func decodeVoiceList(
        _ data: Data,
        kind: VoiceStudioKind,
        wrapperKeys: [String]
    ) throws -> [VoiceStudioVoice] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw VoiceStudioError.invalidResponse(kind: kind, detail: "Expected JSON voice list.")
        }

        let rawItems: [Any]
        if let array = json as? [Any] {
            rawItems = array
        } else if let object = json as? [String: Any] {
            if let found = wrapperKeys.compactMap({ object[$0] as? [Any] }).first {
                rawItems = found
            } else {
                throw VoiceStudioError.invalidResponse(kind: kind, detail: "Voice list JSON object had no voice array.")
            }
        } else {
            throw VoiceStudioError.invalidResponse(kind: kind, detail: "Unexpected voice list format.")
        }

        var voices: [VoiceStudioVoice] = []
        var seenIDs = Set<String>()
        for entry in rawItems {
            guard voices.count < maxVoices else { break }
            guard let item = entry as? [String: Any],
                  let parsed = parseVoiceItem(item, kind: kind),
                  seenIDs.insert(parsed.remoteVoiceID.lowercased()).inserted
            else {
                continue
            }
            voices.append(parsed)
        }
        return voices
    }

    static func decodeSingleProfile(_ data: Data, kind: VoiceStudioKind) throws -> VoiceStudioVoice {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = parseVoiceItem(object, kind: kind)
        else {
            throw VoiceStudioError.invalidResponse(kind: kind, detail: "Studio did not return a valid profile.")
        }
        return parsed
    }

    static func parseVoiceItem(_ item: [String: Any], kind: VoiceStudioKind) -> VoiceStudioVoice? {
        let remoteID = idStringValue(item["id"])
            ?? idStringValue(item["voice_id"])
            ?? idStringValue(item["profile_id"])
        guard let remoteID else { return nil }

        let name = stringValue(item["name"])
            ?? stringValue(item["display_name"])
            ?? stringValue(item["title"])
            ?? remoteID

        let language = stringValue(item["language"]) ?? stringValue(item["lang"])
        let summary = stringValue(item["description"]) ?? stringValue(item["summary"])
        let sampleCount: Int?
        if let count = item["sample_count"] as? Int {
            sampleCount = count
        } else if let samples = item["samples"] as? [Any] {
            sampleCount = samples.count
        } else {
            sampleCount = nil
        }

        return VoiceStudioVoice(
            studioKind: kind,
            remoteVoiceID: remoteID,
            name: name,
            language: language,
            summary: summary,
            sampleCount: sampleCount
        )
    }

    static func extractVersionString(from data: Data) -> String? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let version = stringValue(json["version"]) {
            return version
        }
        if let info = json["info"] as? [String: Any], let version = stringValue(info["version"]) {
            return version
        }
        return nil
    }

    // MARK: - Request & Transport

    static func makeRequest(
        url: URL,
        method: String,
        apiKey: String?,
        timeout: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        let cleanedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedKey.isEmpty {
            request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func performValidated(
        _ request: URLRequest,
        context: VoiceStudioRequestContext,
        budget: VoiceStudioTransferBudget
    ) async throws -> OpenRouterBoundedResponseTransport.Response {
        let response = try await performTransport(request, context: context, budget: budget)
        let status = response.http.statusCode
        guard (200..<300).contains(status) else {
            throw statusError(
                kind: context.kind,
                statusCode: status,
                body: response.body,
                apiKey: context.apiKey
            )
        }
        return response
    }

    static func performTransport(
        _ request: URLRequest,
        context: VoiceStudioRequestContext,
        budget: VoiceStudioTransferBudget
    ) async throws -> OpenRouterBoundedResponseTransport.Response {
        do {
            return try await OpenRouterBoundedResponseTransport.perform(
                request,
                session: context.session,
                limit: budget.limit,
                deadline: budget.deadline
            )
        } catch {
            throw mapTransportError(error, context: context)
        }
    }

    private static func mapTransportError(_ error: Error, context: VoiceStudioRequestContext) -> Error {
        if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
            return CancellationError()
        }
        let baseURL = context.endpoint.sanitizedURLString
        if let transportFailure = error as? OpenRouterBoundedResponseTransport.Failure {
            switch transportFailure {
            case .timedOut:
                return VoiceStudioError.studioNotRunning(kind: context.kind, baseURL: baseURL)
            case .responseTooLarge:
                return VoiceStudioError.invalidResponse(
                    kind: context.kind,
                    detail: "Studio response exceeded the size limit."
                )
            case .invalidResponse:
                return VoiceStudioError.invalidResponse(
                    kind: context.kind,
                    detail: "Studio returned an invalid HTTP response."
                )
            }
        }
        if let urlError = error as? URLError {
            if isTLSError(urlError) {
                return VoiceStudioError.tlsError(kind: context.kind, detail: urlError.localizedDescription)
            }
            if isReachabilityError(urlError) {
                return VoiceStudioError.studioNotRunning(kind: context.kind, baseURL: baseURL)
            }
            return VoiceStudioError.invalidResponse(kind: context.kind, detail: urlError.localizedDescription)
        }
        return VoiceStudioError.studioNotRunning(kind: context.kind, baseURL: baseURL)
    }

    static func statusError(
        kind: VoiceStudioKind,
        statusCode: Int,
        body: Data,
        apiKey: String?
    ) -> VoiceStudioError {
        if statusCode == 401 || statusCode == 403 {
            return .unauthorized(kind: kind, statusCode: statusCode)
        }
        let detail = sanitizedErrorDetail(body, statusCode: statusCode, apiKey: apiKey)
        return .httpError(kind: kind, statusCode: statusCode, detail: detail)
    }

    private static func isTLSError(_ error: URLError) -> Bool {
        switch error.code {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            true
        default:
            false
        }
    }

    private static func isReachabilityError(_ error: URLError) -> Bool {
        switch error.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            true
        default:
            false
        }
    }

    static func sanitizedErrorDetail(_ body: Data, statusCode: Int, apiKey: String?) -> String {
        var detail = ""
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let message = stringValue(json["detail"]) ?? stringValue(json["message"]) {
                detail = message
            } else if let errorString = stringValue(json["error"]) {
                detail = errorString
            } else if let errorObject = json["error"] as? [String: Any],
                      let nestedMessage = stringValue(errorObject["message"]) {
                detail = nestedMessage
            }
        }

        detail = detail.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let cleanedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedKey.isEmpty {
            detail = detail.replacingOccurrences(of: cleanedKey, with: "[REDACTED]")
        }
        if detail.isEmpty {
            return "Request failed with status \(statusCode)."
        }
        if detail.count > 240 {
            return String(detail.prefix(240)) + "…"
        }
        return detail
    }

    // MARK: - Helpers

    static func buildProfilePushBody(
        request: VoiceStudioProfilePushRequest,
        name: String,
        boundary: String
    ) -> Data {
        var body = Data()
        func appendField(_ fieldName: String, value: String) {
            let safeValue = value.replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n".utf8))
            body.append(Data("\(safeValue)\r\n".utf8))
        }

        appendField("name", value: name)
        if let language = normalizedLanguage(request.language) {
            appendField("language", value: language)
        }
        if let transcript = stringValue(request.transcript) {
            appendField("transcript", value: transcript)
        }

        let safeFilename = request.audioFilename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n".utf8)
        )
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(request.audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func startsWithRIFF(_ data: Data) -> Bool {
        data.count >= 12 && data.prefix(4).elementsEqual("RIFF".utf8)
    }

    static func startsWithJSONBrace(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D:
                continue
            case UInt8(ascii: "{"):
                return true
            default:
                return false
            }
        }
        return false
    }

    static func normalizedLanguage(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func stringValue(_ raw: Any?) -> String? {
        guard let string = raw as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func idStringValue(_ raw: Any?) -> String? {
        if let string = stringValue(raw) {
            return string
        }
        if let number = raw as? Int {
            return String(number)
        }
        return nil
    }
}
