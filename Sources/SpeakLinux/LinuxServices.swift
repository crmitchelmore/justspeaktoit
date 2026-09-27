import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Read aloud, the Azure resource, iCloud sync, app profiles, on-device models
/// and start-at-login: the settings panels below History. Returns false for
/// other events. Runs on the GTK thread.
func linuxServiceEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case Int(JSTI_EVENT_READ_ALOUD):
        // Like Copy, the displayed text is read now, paired with the record ID.
        do {
            holder.submitHistoryPlayback(.readAloud(value, text: try LinuxWindow.displayedTranscript()))
        } catch { LinuxHostPlatform.update(error.localizedDescription) }
    case Int(JSTI_EVENT_VOICE):
        let voices = LinuxVoiceOutputSettings.voices
        guard voices.indices.contains(slot) else { break }
        let settings = LinuxVoiceOutputSettings(voice: voices[slot])
        holder.enqueueSettings {
            await controller.saveVoiceOutput(settings)
            LinuxServices.showVoices(await controller.voiceOutputSettings())
        }
    case Int(JSTI_EVENT_AZURE_RESOURCE):
        // Checked here, synchronously; only an accepted entry is saved.
        do {
            let endpoint = try DesktopHostAzureResource.normalized(value)
            holder.enqueueSettings {
                await controller.saveAzureResourceEndpoint(endpoint)
                _ = jsti_window_set_azure_resource(await controller.azureResourceEndpoint())
            }
        } catch { LinuxHostPlatform.update(error.localizedDescription) }
    case Int(JSTI_EVENT_CLOUD_SYNC):
        holder.cloudSync?.handle(
            action: slot & 0xF, history: slot & Int(JSTI_CLOUD_SYNC_HISTORY) != 0,
            keys: slot & Int(JSTI_CLOUD_SYNC_KEYS) != 0, passphrase: value
        )
    default: return linuxLocalServiceEvent(event, value: value, slot: slot, holder: holder)
    }
    return true
}

/// App profiles, on-device models and start at login.
private func linuxLocalServiceEvent(_ event: Int, value: String, slot: Int, holder: LinuxEventContext) -> Bool {
    let controller = holder.controller
    switch event {
    case Int(JSTI_EVENT_OPEN_PROFILES): LinuxServices.openProfiles(holder)
    case Int(JSTI_EVENT_LOCAL_MODEL):
        holder.enqueueSettings { await controller.localModelAction(value, index: slot) }
    case Int(JSTI_EVENT_LOCAL_GPU):
        holder.enqueueSettings { await controller.setLocalUseGPU(slot == 1) }
    case Int(JSTI_EVENT_AUTOSTART):
        let enabled = slot == 1
        holder.enqueueSettings { await LinuxServices.setAutostart(enabled, controller: controller) }
    default: return false
    }
    return true
}

enum LinuxServices {
    /// Hands every panel its saved state before the window runs.
    static func configure(_ holder: LinuxEventContext) async {
        let controller = holder.controller
        showVoices(await controller.voiceOutputSettings())
        _ = jsti_window_set_azure_resource(await controller.azureResourceEndpoint())
        _ = jsti_window_set_profiles_note(LinuxProfilesCoordinator.note(for: LinuxHostPlatform.session))
        await controller.configureLocalModels()
        showAutostart(await controller.startAtLogin(), smokeTest: holder.smokeTest)
    }

    static func showVoices(_ settings: LinuxVoiceOutputSettings) {
        let voices = LinuxVoiceOutputSettings.voices
        let strings = LinuxWindow.Strings()
        let names: [UnsafePointer<CChar>?] = voices.map { strings.add(LinuxVoiceOutputSettings.label($0)) }
        let selected = voices.firstIndex(of: settings.voice) ?? 0
        withExtendedLifetime(strings) {
            names.withUnsafeBufferPointer { _ = jsti_window_set_voices($0.baseAddress, $0.count, Int32(selected)) }
        }
    }

    static func openProfiles(_ holder: LinuxEventContext) {
        let editor = holder.profiles
        guard editor.begin() else { return }
        holder.enqueueSettings {
            do { try editor.show(await holder.controller.profileSnapshot()) } catch {
                editor.cancel()
                LinuxHostPlatform.update(error.localizedDescription)
            }
        }
    }

    // MARK: Start at login

    static var executablePath: String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")) ?? CommandLine.arguments[0]
    }

    static func autostartEntry() -> URL { LinuxAutostart.entryURL(applicationID: linuxApplicationID) }

    static func showAutostart(_ saved: Bool?, smokeTest: Bool) {
        if smokeTest {
            _ = jsti_window_set_autostart(-1, "Not changed by the smoke test.")
        } else if LinuxAutostart.isSandboxed {
            let available = LinuxPortal.version(of: LinuxPortal.background) != nil
            _ = jsti_window_set_autostart(
                available ? (saved == true ? 1 : 0) : -1,
                available ? "Asks the desktop through the Background portal; it may confirm once."
                    : "This desktop has no Background portal, so the app cannot start itself at login."
            )
        } else {
            _ = jsti_window_set_autostart(
                LinuxAutostart.entryEnabled(at: autostartEntry()) ? 1 : 0,
                "Adds a login item at \(autostartEntry().path)."
            )
        }
    }

    static func setAutostart(_ enabled: Bool, controller: LinuxAppController) async {
        do {
            let result: Bool
            if LinuxAutostart.isSandboxed {
                let command = [linuxFlatpakCommand, LinuxAutostart.hiddenArgument]
                result = try await Task.detached { try LinuxAutostart.requestPortal(enabled, command: command) }.value
            } else {
                try LinuxAutostart.setEntry(
                    enabled, at: autostartEntry(), applicationID: linuxApplicationID, executable: executablePath
                )
                result = LinuxAutostart.entryEnabled(at: autostartEntry())
            }
            await controller.saveStartAtLogin(result)
            if enabled, !result {
                await controller.update("The desktop did not allow starting at login.")
            }
        } catch {
            await controller.update("Start at login was not changed: \(error.localizedDescription)")
        }
        showAutostart(await controller.startAtLogin(), smokeTest: false)
    }
}

/// The command the Flatpak exports (the manifest's `command`).
let linuxFlatpakCommand = "justspeaktoit"

extension LinuxAppController {
    func startAtLogin() -> Bool? { settings.startAtLogin }

    func saveStartAtLogin(_ enabled: Bool) {
        guard !closed else { return }
        var changed = settings
        changed.startAtLogin = enabled
        do {
            try effects.writeSettings(
                JSONEncoder().encode(changed), to: directory.appendingPathComponent("settings.json")
            )
            settings = changed
            guard !busy, recording == nil else { return }
            update(enabled ? "Just Speak to It will start when you log in."
                : "Just Speak to It will not start at login.")
        } catch { update("Could not save the start-at-login choice: \(error.localizedDescription)") }
    }
}
