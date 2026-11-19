/// Import support and archive classification are separate capabilities: a
/// provider may reject a codec even when its container is recognized.
public enum RecordingAudioFormats {
    private struct Format: Sendable {
        let fileExtension: String
        var batchImport = true
        var macArchive = false
    }

    private static let formats: [Format] = [
        .init(fileExtension: "aac", macArchive: true),
        .init(fileExtension: "aif"),
        .init(fileExtension: "aiff"),
        .init(fileExtension: "caf", macArchive: true),
        .init(fileExtension: "flac"),
        .init(fileExtension: "m4a", macArchive: true),
        .init(fileExtension: "m4b", batchImport: false, macArchive: true),
        .init(fileExtension: "mp3", macArchive: true),
        .init(fileExtension: "mp4"),
        .init(fileExtension: "ogg"),
        .init(fileExtension: "opus"),
        .init(fileExtension: "wav", macArchive: true),
        .init(fileExtension: "webm")
    ]

    public static let importExtensions = Set(formats.filter(\.batchImport).map(\.fileExtension))
    public static let archiveExtensions = Set(formats.map(\.fileExtension))
    public static let macArchiveExtensions = Set(formats.filter(\.macArchive).map(\.fileExtension))
}
