import Foundation

/// Models API origin, shared by file uploads, streaming adapters and connection warming.
public enum ModulateTranscriptionService {
    public static let baseURL = URL(string: "https://platform.modulate.ai")!
    public static let streamingURL = URL(string: "wss://platform.modulate.ai/api/velma-2-stt-streaming")!
    public static let apiKeysURL = URL(string: "https://platform.modulate.ai/dashboard/api-keys")!
}
