import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ModulateBatchClient {
  public func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure(message: "API key is empty")
    }

    let request = makeValidationRequest(apiKey: trimmed)

    do {
      let (data, response) = try await session.data(
        for: request, delegate: BatchTranscriptionJob.OriginBoundRedirects(origin: baseURL)
      )
      guard let http = response as? HTTPURLResponse else {
        return .failure(message: "Received a non-HTTP response", debug: .capture(request: request))
      }

      let debug = APIKeyValidationDebugSnapshot.capture(request: request, response: http, data: data)
      let detail = parseValidationDetail(from: data)

      switch http.statusCode {
      case 200..<300:
        return .success(message: "Modulate API key validated", debug: debug)
      case 400, 422:
        return .success(
          message: "Modulate API key accepted, but the validation audio payload was rejected.",
          debug: debug
        )
      case 401:
        return .failure(message: detail ?? "Invalid API key.", debug: debug)
      case 403:
        if detail?.localizedCaseInsensitiveContains("invalid_api_key") == true {
          return .failure(message: "Invalid API key.", debug: debug)
        }
        return .failure(
          message: detail ?? "This Modulate model is not enabled for your organisation.",
          debug: debug
        )
      case 429:
        return .success(
          message: "Modulate API key validated, but the current quota or concurrency limit is exhausted.",
          debug: debug
        )
      default:
        return .failure(
          message: "HTTP \(http.statusCode) while validating key",
          debug: debug
        )
      }
    } catch {
      return .failure(
        message: "Validation failed: \(error.localizedDescription)",
        debug: .capture(request: request, error: error)
      )
    }
  }

  private func parseValidationDetail(from data: Data) -> String? {
    guard let error = try? JSONDecoder().decode(ModulateErrorResponse.self, from: data) else { return nil }
    return error.detail
  }

  public func makeValidationRequest(apiKey: String) -> URLRequest {
    let url = baseURL.appendingPathComponent("api/velma-2-stt-batch")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

    var body = Data()
    body.appendFileField(
      named: "upload_file",
      filename: "validation.wav",
      mimeType: "audio/wav",
      fileData: PCMWaveWriter.wavData(pcm: Data(count: 8_000), sampleRate: 16_000)!,
      boundary: boundary
    )
    body.appendString("--\(boundary)--\r\n")
    request.httpBody = body

    return request
  }
}

private struct ModulateErrorResponse: Decodable {
  let detail: String
}
