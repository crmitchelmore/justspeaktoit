import Foundation

extension AutomationRequest {
    public init(
        schemaVersion: Int = AutomationSchema.currentVersion,
        id: String = UUID().uuidString,
        command: AutomationCommand,
        path: String? = nil,
        profile: String? = nil,
        provider: String? = nil,
        limit: Int? = nil,
        timeout: TimeInterval? = nil,
        captureID: String?,
        sinceID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.command = command
        self.path = path
        self.profile = profile
        self.provider = provider
        self.limit = limit
        self.timeout = timeout
        self.captureID = captureID
        self.sinceID = sinceID
    }

    func validateAwait() throws {
        guard let captureID = self.captureID, UUID(uuidString: captureID) != nil,
              captureID.count <= AutomationLimits.maxIdentifierLength else {
            throw AutomationError(code: .invalidArgument, message: "await_transcript requires a capture UUID.")
        }
        if let sinceID = self.sinceID, UUID(uuidString: sinceID) == nil {
            throw AutomationError(code: .invalidArgument, message: "since_id must be a History UUID.")
        }
        guard self.resolvedTimeout.isFinite, self.resolvedTimeout > 0,
              self.resolvedTimeout <= AutomationLimits.maxAwaitTimeout,
              self.path == nil, self.limit == nil, self.profile == nil, self.provider == nil else {
            throw AutomationError(code: .invalidArgument,
                          message: "await_transcript accepts capture/cursor and a finite timeout up to 600 seconds.")
        }

    }
}

extension AutomationResult {
    public init(
        text: String? = nil,
        model: String? = nil,
        durationSeconds: TimeInterval? = nil,
        sessionActive: Bool? = nil,
        appVersion: String? = nil,
        entries: [AutomationHistoryEntry]? = nil,
        captureID: String?,
        entry: AutomationHistoryEntry? = nil
    ) {
        self.text = text
        self.model = model
        self.durationSeconds = durationSeconds
        self.sessionActive = sessionActive
        self.appVersion = appVersion
        self.entries = entries
        self.captureID = captureID
        self.entry = entry
    }
}
