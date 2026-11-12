import Foundation

/// Only disk images reported by macOS qualify for the installer eject prompt.
enum DiskImageMounts {
    static func current() -> Set<String> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return [] }
            return paths(from: data)
        } catch {
            return []
        }
    }

    static func paths(from data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return [] }
        return Set(images.flatMap { image -> [String] in
            guard image["image-path"] is String,
                  let entities = image["system-entities"] as? [[String: Any]] else { return [] }
            return entities.compactMap { $0["mount-point"] as? String }
        })
    }

    /// The disk image file mounted at `mountPoint` in `hdiutil info -plist` output,
    /// or nil when no attached image is mounted there. Throws when the output
    /// is not a property list, so the caller can fall back to a plain eject.
    static func imagePath(mountedAt mountPoint: String, from data: Data) throws -> String? {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return nil }
        for image in images {
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            if entities.contains(where: { $0["mount-point"] as? String == mountPoint }),
               let imagePath = image["image-path"] as? String {
                return imagePath
            }
        }
        return nil
    }
}
