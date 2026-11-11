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
}
