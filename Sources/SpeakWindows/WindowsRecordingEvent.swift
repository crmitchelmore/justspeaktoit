import Foundation
import SpeakDesktopHost
import SpeakWindowsPlatform

/// The original full-await entry point remains available to existing callers.
@discardableResult
func toggleRecording(
    _ controller: WindowsAppController, target: WindowsInsertionTarget?,
    textOutput: Task<WindowsTextOutputOptions, Never>, modelIndex: Int, deviceID: String
) -> Task<Void, Never> {
    Task {
        let options = await textOutput.value
        await controller.toggle(
            target: target, modelIndex: modelIndex, deviceID: deviceID, targetExecutablePath: target?.executablePath,
            textOutput: options
        )
    }
}

@discardableResult
func toggleRecording(
    _ controller: WindowsAppController, target: WindowsInsertionTarget?,
    event: Task<DesktopHostRecordingEvent<WindowsHostPlatform>, Never>, modelIndex: Int, deviceID: String
) -> Task<Void, Never> {
    Task {
        let captured = await event.value
        await controller.toggleCaptured(
            captured, target: target, modelIndex: modelIndex, deviceID: deviceID
        )
    }
}
