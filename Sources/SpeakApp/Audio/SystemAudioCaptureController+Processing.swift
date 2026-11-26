import AVFoundation
import CoreAudio
import Foundation
import SpeakCore

@available(macOS 14.2, *)
extension SystemAudioCaptureController {
    func handleTapInput(
        _ inputData: UnsafePointer<AudioBufferList>,
        tapFormat: AVAudioFormat,
        canonicalFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = bufferList.first, firstBuffer.mDataByteSize > 0 else { return }
        let bytesPerFrame = Int(tapFormat.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let frameCount = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount
        let destination = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: pcmBuffer.audioBufferList)
        )
        let copyCount = min(bufferList.count, destination.count)
        for index in 0..<copyCount {
            guard let src = bufferList[index].mData, let dst = destination[index].mData else { continue }
            let byteCount = min(Int(bufferList[index].mDataByteSize), Int(destination[index].mDataByteSize))
            memcpy(dst, src, byteCount)
            destination[index].mDataByteSize = UInt32(byteCount)
        }

        let samples = convertToCanonicalSamples(pcmBuffer, canonicalFormat: canonicalFormat, using: converter)
        guard !samples.isEmpty else { return }
        enqueueSystemSamples(samples)
    }

    func convertToCanonicalSamples(
        _ buffer: AVAudioPCMBuffer,
        canonicalFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        if buffer.format == canonicalFormat, let channel = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        let ratio = canonicalFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(max(1, Int(ceil(Double(buffer.frameLength) * ratio)) + 16))
        guard let output = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: capacity) else {
            return []
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, status != .error, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    func updateMeter(samples: [Float]) {
        var peak: Float = 0
        var sumSquares: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(max(1, samples.count)))
        let peakDB = peak > 0.000_001 ? 20 * log10(peak) : -160
        let normalized = min(1.0, max(0.0, rms * 4.0))
        recordMeter(level: normalized, peakDecibels: peakDB)
    }

    func stopCaptureHardware() {
        resetMeterStopped()
        let handles = clearHardwareHandles()

        if let engine = handles.micEngine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        if let ioProc = handles.ioProc, handles.aggregateDevice != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(handles.aggregateDevice, ioProc)
            AudioDeviceDestroyIOProcID(handles.aggregateDevice, ioProc)
        }
        if handles.aggregateDevice != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(handles.aggregateDevice)
        }
        if handles.tap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(handles.tap)
        }
    }
}
