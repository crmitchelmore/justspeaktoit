import Foundation

extension DesktopHostController {
    package func revealRecordingsDirectory() async {
        guard !closed else { return }
        guard folderRevealTask == nil else {
            Platform.update("A recording folder request is already running.")
            return
        }
        activeOperations += 1
        defer { folderRevealTask = nil; finishOperation() }
        do {
            let folder = await recordingsFolderToReveal()
            let task = Task.detached {
                try Task.checkCancellation()
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    throw DesktopHostError(message: "The recording storage folder is unavailable.")
                }
                try Task.checkCancellation()
                try Platform.revealDirectory(folder)
            }
            folderRevealTask = task
            try await task.value
            guard !closed, !DesktopHostRecordingLocation.isQualifiedPlatform else { return }
            Platform.update("Opened the History recordings folder. "
                + "Choosing a different recordings folder is not yet available on this platform.")
        } catch {
            guard !closed else { return }
            Platform.update("Could not open the recordings folder: \(error.localizedDescription)")
        }
    }
}
