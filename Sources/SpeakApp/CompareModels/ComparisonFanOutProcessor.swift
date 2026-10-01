import AVFoundation
import Foundation
import SpeakCore
import os.log

/// Converts each microphone tap buffer once per distinct target format and
/// fans the PCM out to every lane at that format, off the render thread.
///
/// The same pooled-copy, cached-converter, no-`reset()` discipline as
/// `SharedClientAudioProcessor`, generalised from one client to N. Every tap
/// buffer is also resampled to 16 kHz and appended to the retained capture.
final class ComparisonFanOutProcessor: @unchecked Sendable {
    private struct Target {
        let format: AVAudioFormat
        let converter = LiveConverterCache()
        let chunker: ComparisonPCMChunker
        var clients: [StreamingTranscriptionClient]
    }

    private let queue = DispatchQueue(label: "com.speak.app.compareModels.audioProcessing")
    private let copyBufferPool = LivePCMBufferPool(maximumBuffers: 6, tapBufferSize: 4096, label: "compare-models")
    private let logger = SpeakLogger.logger(category: "ComparisonFanOut")
    private var isRunning = false
    private var inputFormat: AVAudioFormat?
    private var targets: [Int: Target] = [:]
    private var appleLanes: [(session: AppleLiveSessionBox, converter: AppleSpeechAudioConverterBox)] = []
    private var capture = Data()
    private var captureConverter = LiveConverterCache()
    private var captureFormat: AVAudioFormat?

    /// Registers the consumers for this capture. `clients` pairs each shared
    /// client with the sample rate it expects; clients at the same rate share
    /// one converter.
    func configure(
        clients: [(client: StreamingTranscriptionClient, sampleRate: Int)],
        appleLanes: [(session: AppleLiveSessionBox, converter: AppleSpeechAudioConverterBox)],
        inputFormat: AVAudioFormat
    ) {
        queue.sync {
            self.inputFormat = inputFormat
            targets = [:]
            self.appleLanes = appleLanes
            capture = Data()
            captureConverter = LiveConverterCache()
            captureFormat = Self.pcm16Format(sampleRate: ComparisonLiveFanOut.captureSampleRate)
            for (client, rate) in clients {
                if targets[rate] == nil, let format = Self.pcm16Format(sampleRate: rate) {
                    targets[rate] = Target(format: format, chunker: ComparisonPCMChunker(sampleRate: rate), clients: [])
                }
                targets[rate]?.clients.append(client)
            }
            isRunning = true
        }
    }

    /// Stops accepting audio, flushes every resampler's tail to its clients,
    /// and returns the retained 16 kHz capture.
    func finish() -> Data {
        queue.sync {
            isRunning = false
            for target in targets.values {
                if let tail = target.converter.drainPCM16() {
                    if Int(target.format.sampleRate) == ComparisonLiveFanOut.captureSampleRate { capture.append(tail) }
                    target.chunker.append(tail) { packet in
                        for client in target.clients { client.sendAudio(packet) }
                    }
                }
                target.chunker.finish { packet in
                    for client in target.clients { client.sendAudio(packet) }
                }
            }
            if targets[ComparisonLiveFanOut.captureSampleRate] == nil,
               let tail = captureConverter.drainPCM16() {
                capture.append(tail)
            }
            targets = [:]
            appleLanes = []
            copyBufferPool.removeAll()
            let result = capture
            capture = Data()
            return result
        }
    }

    func handleAudioTap(_ buffer: AVAudioPCMBuffer) {
        guard let copied = copyPCMBuffer(buffer) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.copyBufferPool.recycle(copied) }
            guard self.isRunning, let inputFormat = self.inputFormat else { return }
            self.process(copied, inputFormat: inputFormat)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        for target in targets.values {
            guard let data = Self.convertToPCM16(
                buffer, from: inputFormat, to: target.format, cache: target.converter, logger: logger
            ) else { continue }
            if Int(target.format.sampleRate) == ComparisonLiveFanOut.captureSampleRate { capture.append(data) }
            target.chunker.append(data) { packet in
                for client in target.clients { client.sendAudio(packet) }
            }
        }
        if targets[ComparisonLiveFanOut.captureSampleRate] == nil, let captureFormat,
           let data = Self.convertToPCM16(
               buffer, from: inputFormat, to: captureFormat, cache: captureConverter, logger: logger
           ) {
            capture.append(data)
        }
        // The Apple session accepts buffers from the audio queue directly,
        // exactly as the dictation controller's tap feeds it.
        for (session, converter) in appleLanes {
            if let converted = converter.convert(buffer) {
                session.send(converted)
            }
        }
    }

    private func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = buffer.frameLength
        guard frameLength > 0,
              let copy = copyBufferPool.buffer(format: buffer.format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: copy.audioBufferList))
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData, let destinationData = destination[index].mData else { continue }
            destinationData.copyMemory(from: sourceData, byteCount: Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        return copy
    }

    static func pcm16Format(sampleRate: Int) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)
    }

    private static func convertToPCM16(
        _ buffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat,
        to outputFormat: AVAudioFormat,
        cache: LiveConverterCache,
        logger: Logger
    ) -> Data? {
        guard let converter = cache.converter(from: inputFormat, to: outputFormat) else {
            logger.error("Failed to create audio converter")
            return nil
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard !didProvideInput else {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil else {
            logger.error("Audio conversion failed")
            return nil
        }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: frameCount * 2)
    }
}
