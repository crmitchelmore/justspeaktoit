import AppKit
import Foundation
import SpeakCore

/// First-launch housekeeping for direct-download installs: offers to move an
/// app launched from its installer image into Applications, and to eject (and
/// optionally trash) the installer image once the app runs from Applications.
@MainActor
enum DiskImageInstallCleanup {
    static func offerIfNeeded() {
        // DMG installs exist only on the direct-download channel. The App Store
        // build is installed by the store and sandboxed, so probing /Volumes,
        // spawning hdiutil, and copying into /Applications would only produce
        // spurious dialogs and guaranteed failures there.
        guard DistributionChannel.current == .direct else { return }

        let bundlePath = Bundle.main.bundlePath

        // Only a read-only mount (an installer DMG or an App Translocation
        // image) counts. External drives mount under /Volumes too, and a
        // build living there must not be nagged to move.
        if DiskImageDetector.isRunningFromDiskImage(bundleURL: Bundle.main.bundleURL) {
            // Running from DMG - suggest moving to Applications
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                showMoveToApplicationsAlert()
            }
        } else if bundlePath.hasPrefix("/Applications") {
            // Only check for mounted installer DMGs on the very first launch.
            // After the first launch, any mounted DMG is likely from a Sparkle
            // auto-update and should not trigger the eject dialog.
            let hasLaunchedKey = "justspeaktoit.hasLaunchedBefore"
            guard !UserDefaults.standard.bool(forKey: hasLaunchedKey) else { return }
            UserDefaults.standard.set(true, forKey: hasLaunchedKey)

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                checkForMountedDMG()
            }
        }
    }

    private static func showMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "Move to Applications?"
        alert.informativeText = "\(RunningAppIdentity.current.name) is running from a disk image. "
            + "Would you like to move it to your Applications folder for better performance?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            moveToApplications()
        }
    }

    private static func moveToApplications() {
        let bundlePath = Bundle.main.bundlePath
        let appName = (bundlePath as NSString).lastPathComponent
        let destinationPath = "/Applications/\(appName)"

        do {
            // Remove existing app if present
            if FileManager.default.fileExists(atPath: destinationPath) {
                try FileManager.default.removeItem(atPath: destinationPath)
            }

            // Copy to Applications
            try FileManager.default.copyItem(atPath: bundlePath, toPath: destinationPath)

            // Launch from new location
            let url = URL(fileURLWithPath: destinationPath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                // Quit the current instance
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could not move application"
            errorAlert.informativeText = "Please drag \(RunningAppIdentity.current.name) to your Applications folder. "
                + "Error: \(error.localizedDescription)"
            errorAlert.runModal()
        }
    }

    private static func checkForMountedDMG() {
        let fileManager = FileManager.default

        // Only show eject dialog once per volume - track which volumes we've asked about
        // This prevents the dialog from appearing after Sparkle auto-updates
        let askedVolumesKey = "justspeaktoit.askedToEjectVolumes"
        var askedVolumes = Set(UserDefaults.standard.stringArray(forKey: askedVolumesKey) ?? [])

        do {
            let volumes = try fileManager.contentsOfDirectory(atPath: "/Volumes")
            let imageMounts = DiskImageMounts.current()

            for volume in volumes {
                let volumePath = "/Volumes/\(volume)"
                let appPath = "\(volumePath)/\(Bundle.main.bundleURL.lastPathComponent)"

                // Check if this looks like our DMG
                if imageMounts.contains(volumePath), fileManager.fileExists(atPath: appPath) {
                    // Skip if we've already asked about this volume
                    if askedVolumes.contains(volume) {
                        continue
                    }

                    // Remember we asked about this volume
                    askedVolumes.insert(volume)
                    UserDefaults.standard.set(Array(askedVolumes), forKey: askedVolumesKey)

                    showEjectDMGAlert(volumeName: volume)
                    break
                }
            }
        } catch {
            // Ignore errors reading volumes
        }
    }

    private static func showEjectDMGAlert(volumeName: String) {
        let alert = NSAlert()
        alert.messageText = "Eject Installer?"
        alert.informativeText = "\(RunningAppIdentity.current.name) has been installed. "
            + "Would you like to eject the installer disk image and move it to Trash?"
        alert.addButton(withTitle: "Eject & Trash")
        alert.addButton(withTitle: "Just Eject")
        alert.addButton(withTitle: "Keep Mounted")
        alert.alertStyle = .informational

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Eject and trash
            ejectAndTrashDMG(volumeName: volumeName)
        } else if response == .alertSecondButtonReturn {
            // Just eject
            ejectDMG(volumeName: volumeName)
        }
    }

    private static func ejectDMG(volumeName: String) {
        let volumePath = "/Volumes/\(volumeName)"
        NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath)
    }

    private static func ejectAndTrashDMG(volumeName: String) {
        // First, find the DMG file path before ejecting
        let volumePath = "/Volumes/\(volumeName)"

        // Get disk info to find source DMG
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["info", "-plist"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let imagePath = try DiskImageMounts.imagePath(mountedAt: volumePath, from: data) {
                // Eject first
                NSWorkspace.shared.unmountAndEjectDevice(atPath: volumePath)

                // Then trash the DMG
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let dmgURL = URL(fileURLWithPath: imagePath)
                    try? FileManager.default.trashItem(at: dmgURL, resultingItemURL: nil)
                }
            }
        } catch {
            // Fallback: just eject
            ejectDMG(volumeName: volumeName)
        }
    }
}
