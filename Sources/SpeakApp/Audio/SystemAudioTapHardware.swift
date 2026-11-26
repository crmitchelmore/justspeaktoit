import AVFoundation
import CoreAudio
import Foundation

/// Low-level CoreAudio Process Tap helpers used by `SystemAudioCaptureController`.
@available(macOS 14.2, *)
enum SystemAudioTapHardware {
    struct CreatedTap {
        let tapID: AudioObjectID
        let tapFormat: AVAudioFormat
        let aggregateDeviceID: AudioObjectID
    }

    static func createGlobalTapExcludingSelf() throws -> CreatedTap {
        let excluded = currentProcessAudioObjectID().map { [$0] } ?? []
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.name = "Just Speak System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioCaptureError.processTapFailed(tapStatus)
        }

        do {
            let tapFormat = try readTapFormat(tapID: tapID)
            let aggregateDeviceID = try createAggregateDevice(tapUUID: description.uuid.uuidString)
            return CreatedTap(tapID: tapID, tapFormat: tapFormat, aggregateDeviceID: aggregateDeviceID)
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    static func makeOutputFile(at url: URL, sampleRate: Double) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw SystemAudioCaptureError.fileCreationFailed
        }
    }

    private static func createAggregateDevice(tapUUID: String) throws -> AudioObjectID {
        let aggregateUID = "com.justspeaktoit.system-audio-aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Just Speak System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceIsPrivateKey: true
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID)
        guard status == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemAudioCaptureError.aggregateDeviceFailed(status)
        }
        return deviceID
    }

    private static func readTapFormat(tapID: AudioObjectID) throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SystemAudioCaptureError.invalidTapFormat
        }
        return format
    }

    private static func currentProcessAudioObjectID() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObject
        )
        guard status == noErr, processObject != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return processObject
    }
}
