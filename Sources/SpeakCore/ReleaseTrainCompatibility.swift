import Foundation

// Preserve pre-Alpha public signatures for existing library clients.
extension ReleaseNoteEntry {
    public init(
        version: String, tag: String, publishedAt: String, markdown: String,
        platform: ReleaseNotesPlatform? = nil
    ) {
        self.init(version: version, tag: tag, publishedAt: publishedAt, markdown: markdown,
                  platform: platform, train: .stable)
    }
}

extension ReleaseNotesCatalog {
    public func entries(for platform: ReleaseNotesPlatform) -> [ReleaseNoteEntry] {
        entries(for: platform, train: .current)
    }
}

extension ReleaseNotesBrowser {
    public init(
        catalog: ReleaseNotesCatalog = .bundled,
        installedVersion: String = ReleaseNotesCatalog.installedVersion(),
        platform: ReleaseNotesPlatform = .current
    ) {
        self.init(catalog: catalog, installedVersion: installedVersion, platform: platform, train: .current)
    }
}

extension HelloMessage {
    public init(protocolVersion: Int = SpeakTransportProtocolVersion, deviceName: String, deviceId: String) {
        self.init(protocolVersion: protocolVersion, deviceName: deviceName, deviceId: deviceId, releaseTrain: .current)
    }
}

extension AuthResultMessage {
    public init(success: Bool, sessionToken: String? = nil, errorMessage: String? = nil) {
        self.init(success: success, sessionToken: sessionToken, errorMessage: errorMessage, releaseTrain: .current)
    }
}
