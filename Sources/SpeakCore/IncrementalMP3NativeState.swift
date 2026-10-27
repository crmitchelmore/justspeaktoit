#if canImport(AudioToolbox) && !SPEAK_PORTABLE_CORE
import AudioToolbox
import Foundation

/// Confined to IncrementalMP3Decoder. No native callback schedules asynchronous work.
final class IncrementalMP3NativeState {
    private struct Packet {
        let bytes: Data
        let frames: UInt32
    }

    private static let needsMoreInput: OSStatus = 0x6D703369 // mp3i, distinct from EOF
    private var stream: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var sourceFormat: AudioStreamBasicDescription?
    private var channels: UInt32 = 0
    private var packets: [Packet] = []
    private var queuedBytes = 0
    private var callbackFailure: IncrementalMP3Decoder.Failure?
    private var eof = false
    private var stagedInput = Data()
    private var mayDrain = false
    private var inputStorage: NSData?
    private let inputDescription = MP3PacketDescriptionStorage()

    init() throws {
        let status = AudioFileStreamOpen(
            Unmanaged.passUnretained(self).toOpaque(), mp3PropertyListener, mp3PacketsListener,
            kAudioFileMP3Type, &stream
        )
        guard status == noErr, stream != nil else {
            close()
            throw IncrementalMP3Decoder.Failure.unavailable
        }
    }

    deinit {
        close()
    }

    func close() {
        if let stream { AudioFileStreamClose(stream) }
        if let converter { AudioConverterDispose(converter) }
        stream = nil
        converter = nil
        packets.removeAll()
        queuedBytes = 0
        inputStorage = nil
        stagedInput.removeAll()
        mayDrain = false
    }

    func append(_ data: Data) throws {
        guard let stream, !eof else { throw IncrementalMP3Decoder.Failure.invalidAudio }
        guard !data.isEmpty else { return }
        guard data.count <= IncrementalMP3Decoder.maximumCompressedBytes - stagedInput.count -
            queuedBytes - (inputStorage?.length ?? 0) else { throw IncrementalMP3Decoder.Failure.invalidAudio }
        // AudioFileStream's MP3 parsing is sensitive to tiny ParseBytes calls.
        // Give it deterministic blocks independently of HTTP fragment boundaries.
        stagedInput.append(data)
        while stagedInput.count >= 1024 {
            let block = Data(stagedInput.prefix(1024))
            stagedInput.removeFirst(1024)
            try parse(block, stream: stream)
        }
    }

    private func parse(_ data: Data, stream: AudioFileStreamID) throws {
        let status = data.withUnsafeBytes {
            AudioFileStreamParseBytes(stream, UInt32($0.count), $0.baseAddress, [])
        }
        try check(status)
        mayDrain = true
    }

    func finishInput() throws {
        guard let stream, !eof else { throw IncrementalMP3Decoder.Failure.invalidAudio }
        if !stagedInput.isEmpty {
            let residual = stagedInput
            stagedInput.removeAll()
            try parse(residual, stream: stream)
        }
        // AudioFileStream explicitly requires a zero-byte parse to flush at EOF.
        let status = AudioFileStreamParseBytes(stream, 0, nil, [])
        try check(status)
        eof = true
        mayDrain = true
        guard converter != nil else { throw IncrementalMP3Decoder.Failure.invalidAudio }
    }

    func nextPCM() throws -> Data? {
        if let callbackFailure { throw callbackFailure }
        guard let converter, mayDrain else { return nil }
        let capacity = IncrementalMP3Decoder.maximumPCMFrames * Int(channels) * 2
        var output = Data(count: capacity)
        var frames = UInt32(IncrementalMP3Decoder.maximumPCMFrames)
        let status = output.withUnsafeMutableBytes { raw in
            var buffers = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: channels, mDataByteSize: UInt32(capacity), mData: raw.baseAddress
                )
            )
            return AudioConverterFillComplexBuffer(
                converter, mp3ConverterInput, Unmanaged.passUnretained(self).toOpaque(), &frames, &buffers, nil
            )
        }
        guard status == noErr || status == Self.needsMoreInput,
              frames <= UInt32(IncrementalMP3Decoder.maximumPCMFrames) else {
            throw IncrementalMP3Decoder.Failure.invalidAudio
        }
        guard frames > 0 else {
            mayDrain = false
            return nil
        }
        output.count = Int(frames) * Int(channels) * 2
        return try Self.monoPCM(output, channels: channels)
    }

    /// AudioConverter's default stereo-to-mono map discards the right channel.
    /// Convert at the source channel count, then explicitly average both channels.
    static func monoPCM(_ data: Data, channels: UInt32) throws -> Data {
        guard channels == 1 || channels == 2, data.count % (Int(channels) * 2) == 0 else {
            throw IncrementalMP3Decoder.Failure.invalidAudio
        }
        guard channels == 2 else { return data }
        let bytes = [UInt8](data)
        var mono = Data(capacity: data.count / 2)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let left = Int32(Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8))
            let right = Int32(Int16(bitPattern: UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8))
            let sample = UInt16(bitPattern: Int16((left + right) / 2))
            mono.append(UInt8(truncatingIfNeeded: sample))
            mono.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return mono
    }

    fileprivate func propertyChanged(_ stream: AudioFileStreamID, property: AudioFileStreamPropertyID) {
        guard callbackFailure == nil, property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        do { try configureConverter(stream) } catch {
            callbackFailure = (error as? IncrementalMP3Decoder.Failure) ?? .invalidAudio
        }
    }

    private func configureConverter(_ stream: AudioFileStreamID) throws {
        var source = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: source))
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &source) == noErr,
              source.mFormatID == kAudioFormatMPEGLayer3, (1...2).contains(source.mChannelsPerFrame),
              source.mSampleRate.isFinite, (8_000...96_000).contains(source.mSampleRate) else {
            throw IncrementalMP3Decoder.Failure.invalidAudio
        }
        guard converter == nil else { throw IncrementalMP3Decoder.Failure.invalidAudio }
        channels = source.mChannelsPerFrame
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(IncrementalMP3Decoder.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 2, mFramesPerPacket: 1, mBytesPerFrame: channels * 2,
            mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0
        )
        guard AudioConverterNew(&source, &output, &converter) == noErr, let converter else {
            throw IncrementalMP3Decoder.Failure.unavailable
        }
        var actual = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout.size(ofValue: actual))
        let outputStatus = AudioConverterGetProperty(
            converter, kAudioConverterCurrentOutputStreamDescription, &size, &actual
        )
        guard outputStatus == noErr,
              actual.mFormatID == output.mFormatID, actual.mFormatFlags == output.mFormatFlags,
              actual.mSampleRate == output.mSampleRate, actual.mChannelsPerFrame == channels,
              actual.mBitsPerChannel == 16, actual.mBytesPerFrame == channels * 2,
              actual.mFramesPerPacket == 1 else { throw IncrementalMP3Decoder.Failure.invalidAudio }
        sourceFormat = source
    }

    fileprivate func receivePackets(
        bytes: UInt32, count: UInt32, data: UnsafeRawPointer, descriptions: UnsafePointer<AudioStreamPacketDescription>?
    ) {
        guard callbackFailure == nil else { return }
        let remaining = IncrementalMP3Decoder.maximumCompressedBytes - queuedBytes -
            (inputStorage?.length ?? 0) - stagedInput.count
        guard count > 0, count <= bytes, bytes > 0, Int(bytes) <= remaining else {
            callbackFailure = .invalidAudio
            return
        }
        for index in 0..<Int(count) {
            let offset: Int
            let size: Int
            let frames: UInt32
            if let descriptions {
                let packet = descriptions[index]
                guard packet.mStartOffset >= 0, packet.mStartOffset <= Int64(bytes) else {
                    callbackFailure = .invalidAudio
                    return
                }
                offset = Int(packet.mStartOffset)
                size = Int(packet.mDataByteSize)
                frames = packet.mVariableFramesInPacket
            } else {
                guard bytes % count == 0 else { callbackFailure = .invalidAudio; return }
                size = Int(bytes / count)
                offset = index * size
                frames = sourceFormat?.mFramesPerPacket ?? 0
            }
            guard size > 0, size <= Int(bytes) - offset,
                  size <= IncrementalMP3Decoder.maximumCompressedBytes - queuedBytes -
                    (inputStorage?.length ?? 0) - stagedInput.count else {
                callbackFailure = .invalidAudio
                return
            }
            packets.append(Packet(bytes: Data(bytes: data.advanced(by: offset), count: size), frames: frames))
            queuedBytes += size
        }
    }

    fileprivate func supplyInput(
        count: UnsafeMutablePointer<UInt32>, buffers: UnsafeMutablePointer<AudioBufferList>,
        descriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        guard count.pointee > 0 else {
            count.pointee = 0
            return kAudio_ParamError
        }
        inputStorage = nil
        guard !packets.isEmpty else {
            count.pointee = 0
            buffers.pointee.mBuffers.mData = nil
            buffers.pointee.mBuffers.mDataByteSize = 0
            descriptions?.pointee = nil
            return eof ? noErr : Self.needsMoreInput
        }
        guard let descriptions else {
            count.pointee = 0
            return kAudio_ParamError
        }
        let packet = packets.removeFirst()
        queuedBytes -= packet.bytes.count
        inputStorage = packet.bytes as NSData
        inputDescription.pointer.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: packet.frames, mDataByteSize: UInt32(packet.bytes.count)
        )
        count.pointee = 1
        buffers.pointee.mNumberBuffers = 1
        buffers.pointee.mBuffers = AudioBuffer(
            mNumberChannels: channels, mDataByteSize: UInt32(packet.bytes.count),
            mData: UnsafeMutableRawPointer(mutating: inputStorage?.bytes)
        )
        descriptions.pointee = inputDescription.pointer
        return noErr
    }

    private func check(_ status: OSStatus) throws {
        if let callbackFailure { throw callbackFailure }
        guard status == noErr else { throw IncrementalMP3Decoder.Failure.invalidAudio }
    }
}

/// ARC releases this allocation even when native-state initialization throws.
private final class MP3PacketDescriptionStorage {
    let pointer = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    init() { pointer.initialize(to: AudioStreamPacketDescription()) }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
}

private let mp3PropertyListener: AudioFileStream_PropertyListenerProc = { context, stream, property, _ in
    Unmanaged<IncrementalMP3NativeState>.fromOpaque(context).takeUnretainedValue()
        .propertyChanged(stream, property: property)
}

private let mp3PacketsListener: AudioFileStream_PacketsProc = { context, bytes, count, data, descriptions in
    Unmanaged<IncrementalMP3NativeState>.fromOpaque(context).takeUnretainedValue()
        .receivePackets(bytes: bytes, count: count, data: data, descriptions: descriptions)
}

private let mp3ConverterInput: AudioConverterComplexInputDataProc = { _, count, buffers, descriptions, context in
    guard let context else { count.pointee = 0; return kAudio_ParamError }
    return Unmanaged<IncrementalMP3NativeState>.fromOpaque(context).takeUnretainedValue()
        .supplyInput(count: count, buffers: buffers, descriptions: descriptions)
}
#endif
