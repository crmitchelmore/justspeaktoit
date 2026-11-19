// Playback self-test: the ring, source validation, the decoder and a stalled decode.
#include "WindowsPlaybackSelfTestSupport.hpp"

namespace jsti::playback::selftest {

int selfTestRing(char *error, size_t capacity) {
    PCMByteRing ring(16, 4);
    std::array<uint8_t, 32> source{}, sink{};
    for (size_t index = 0; index < source.size(); ++index) source[index] = static_cast<uint8_t>(index + 1);
    if (ring.size() != 16 || ring.writable() != 16 || ring.readable() != 0 || ring.read(sink.data(), 8) != 0) {
        return jsti::fail("The playback queue did not start empty.", error, capacity);
    }
    if (ring.write(source.data(), 10) != 10 || ring.writable() != 6 || ring.readable() != 8) {
        return jsti::fail("The playback queue miscounted a partial-frame write.", error, capacity);
    }
    if (ring.read(sink.data(), 12) != 8 || !std::equal(sink.begin(), sink.begin() + 8, source.begin()) || ring.readable() != 0) {
        return jsti::fail("The playback queue handed out a partial frame.", error, capacity);
    }
    if (ring.write(source.data() + 10, 20) != 14 || ring.writable() != 0 || ring.write(source.data(), 1) != 0 ||
        ring.readable() != 16) {
        return jsti::fail("The playback queue exceeded its fixed capacity.", error, capacity);
    }
    if (ring.read(sink.data(), 16) != 16 || !std::equal(sink.begin(), sink.begin() + 16, source.begin() + 8) ||
        ring.readable() != 0 || ring.writable() != 16) {
        return jsti::fail("The playback queue lost order across its wrap boundary.", error, capacity);
    }
    for (int pass = 0; pass < 5; ++pass) {
        if (ring.write(source.data(), 12) != 12 || ring.read(sink.data(), 12) != 12 ||
            !std::equal(sink.begin(), sink.begin() + 12, source.begin())) {
            return jsti::fail("The playback queue failed repeated wrap passes.", error, capacity);
        }
    }
    return 0;
}

int selfTestSourceValidation(const std::wstring &fixture, const std::wstring &root, char *error, size_t capacity) {
    jsti::Handle handle;
    uint64_t size = 0;
    try {
        openSource(fixture, 100, handle, size);
        return jsti::fail("Audio playback did not enforce its input byte limit.", error, capacity);
    } catch (const Failure &failure) {
        if (describe(failure).find("exceeds") == std::string::npos) return jsti::fail(describe(failure), error, capacity);
    }
    if (handle.value || !writable(fixture)) {
        return jsti::fail("Refusing an oversized input retained its file handle.", error, capacity);
    }
    try {
        openSource(root, inputLimit, handle, size);
        return jsti::fail("Audio playback accepted a directory as input.", error, capacity);
    } catch (const Failure &) {}
    try {
        openSource(fixture + L".missing", inputLimit, handle, size);
        return jsti::fail("Audio playback accepted a missing input.", error, capacity);
    } catch (const Failure &) {}
    openSource(fixture, inputLimit, handle, size);
    if (!handle.value || size != waveHeaderSize + uint64_t{shortFrames} * 2) {
        return jsti::fail("Audio playback measured its input incorrectly.", error, capacity);
    }
    if (writable(fixture)) return jsti::fail("The pinned playback input could be opened for writing.", error, capacity);
    const HANDLE owned = handle.value;
    bool existingRefused = false;
    try { openSource(fixture, inputLimit, handle, size); } catch (const Failure &) { existingRefused = true; }
    if (!existingRefused || handle.value != owned) {
        return jsti::fail("Opening into an owned input replaced or lost its handle.", error, capacity);
    }
    const FormatSpec mix = floatFormat(48000, 2, stereoMask);
    if (mix.blockAlign != 8 || mix.byteRate() != 48000 * 8 || sampleBound(mix) != 48000 * 8 * sampleBoundSeconds ||
        sampleBound(pcm16Format(8000, 1)) != minimumSampleBound) {
        return jsti::fail("Format bounds were not derived from the output format.", error, capacity);
    }
    bool refused = false;
    try { floatFormat(48000, 9, 0); } catch (const Failure &) { refused = true; }
    if (!refused) return jsti::fail("A nine-channel output format was accepted.", error, capacity);
    return 0;
}

struct DecodeStats {
    uint64_t bytes = 0;
    size_t chunks = 0;
    bool aligned = true;
    float peak = 0;
    std::vector<uint8_t> collected;
};

int selfTestDecoder(const std::wstring &fixture, const std::wstring &longFixture, const std::wstring &corrupt,
                    char *error, size_t capacity) {
    MediaPlatform platform;
    platform.initialise();
    std::atomic<bool> never{false};
    // Same rate and layout as the file: Windows must pass the samples through untouched.
    {
        Decoder decoder(never, std::make_shared<ReadState>());
        jsti::Handle handle;
        uint64_t size = 0;
        openSource(fixture, inputLimit, handle, size);
        decoder.open(handle, size, fixture);
        const int64_t ticks = decoder.durationTicks();
        if (ticks < 999900 || ticks > 1000100) return jsti::fail("The WAV duration was not reported as 0.1 s.", error, capacity);
        require(decoder.configure(pcm16Format(fixtureRate, 1)), "Configure exact PCM16 decode");
        if (decoder.sampleBytesBound() != minimumSampleBound) return jsti::fail("The PCM16 sample bound was not derived.", error, capacity);
        DecodeStats stats;
        while (decoder.next([&](const uint8_t *data, size_t length) {
            stats.collected.insert(stats.collected.end(), data, data + length);
            ++stats.chunks;
        })) {}
        decoder.close();
        if (stats.chunks == 0 || decoder.bytesDecoded() != stats.collected.size() ||
            !matchesFixture(stats.collected.data(), stats.collected.size(), shortFrames)) {
            return jsti::fail("Exact PCM16 decode changed sample values or counts.", error, capacity);
        }
        if (!writable(fixture) || !verifyWaveFixture(fixture, shortFrames)) {
            return jsti::fail("Decoding modified the synthetic source or kept it pinned after close.", error, capacity);
        }
    }
    // A typical endpoint mix format: Windows resamples and upmixes to float.
    {
        Decoder decoder(never, std::make_shared<ReadState>());
        jsti::Handle handle;
        uint64_t size = 0;
        openSource(fixture, inputLimit, handle, size);
        decoder.open(handle, size, fixture);
        const FormatSpec mix = floatFormat(48000, 2, stereoMask);
        require(decoder.configure(mix), "Windows decoder cannot convert PCM16 to 48 kHz stereo float");
        if (decoder.format().blockAlign != 8) return jsti::fail("The float target format has the wrong frame size.", error, capacity);
        DecodeStats stats;
        while (decoder.next([&](const uint8_t *data, size_t length) {
            stats.bytes += length;
            ++stats.chunks;
            if (length % 8) stats.aligned = false;
            for (size_t offset = 0; offset + 4 <= length; offset += 4) {
                float sample = 0;
                std::memcpy(&sample, data + offset, sizeof(sample));
                stats.peak = std::max(stats.peak, std::abs(sample));
            }
        })) {}
        decoder.close();
        const uint64_t frames = stats.bytes / 8;
        // 0.1 s at 48 kHz is 4800 frames; the resampler may add or drop a few.
        if (!stats.aligned || stats.chunks == 0 || frames < 4640 || frames > 4960) {
            return jsti::fail("Float 48 kHz stereo decode produced a wrong or misaligned frame count.", error, capacity);
        }
        const float expected = static_cast<float>(fixtureAmplitude) / 32768.0f;
        if (stats.peak < expected * 0.5f || stats.peak > expected * 2.0f) {
            return jsti::fail("Float decode changed the low fixture amplitude.", error, capacity);
        }
    }
    // The decoded-sample bound is enforced before the contiguous copy.
    {
        Decoder decoder(never, std::make_shared<ReadState>());
        jsti::Handle handle;
        uint64_t size = 0;
        openSource(fixture, inputLimit, handle, size);
        decoder.open(handle, size, fixture);
        require(decoder.configure(pcm16Format(fixtureRate, 1), 100), "Configure bounded decode");
        bool refused = false;
        size_t delivered = 0;
        try {
            while (decoder.next([&](const uint8_t *, size_t) { ++delivered; })) {}
        } catch (const Failure &failure) { refused = describe(failure).find("sample bound") != std::string::npos; }
        if (!refused || delivered) return jsti::fail("An oversized decoded sample was coalesced or delivered.", error, capacity);
    }
    // Cancellation while decoding: the next sample request throws promptly.
    {
        std::atomic<bool> cancelled{false};
        Decoder decoder(cancelled, std::make_shared<ReadState>());
        jsti::Handle handle;
        uint64_t size = 0;
        openSource(longFixture, inputLimit, handle, size);
        decoder.open(handle, size, longFixture);
        require(decoder.configure(floatFormat(48000, 2, stereoMask)), "Configure cancellation decode");
        bool threw = false;
        size_t chunks = 0;
        try {
            while (decoder.next([&](const uint8_t *, size_t) { ++chunks; cancelled.store(true); })) {}
        } catch (const Cancelled &) { threw = true; }
        if (!threw || chunks != 1) return jsti::fail("Decode cancellation was not honoured after the first sample.", error, capacity);
        decoder.close();
    }
    // Junk bytes: no installed codec accepts them, and the error says so.
    {
        Decoder decoder(never, std::make_shared<ReadState>());
        jsti::Handle handle;
        uint64_t size = 0;
        openSource(corrupt, inputLimit, handle, size);
        bool threw = false;
        try {
            decoder.open(handle, size, corrupt);
            require(decoder.configure(floatFormat(48000, 2, stereoMask)), "Configure corrupt decode");
            while (decoder.next([](const uint8_t *, size_t) {})) {}
        } catch (const Failure &failure) { threw = !describe(failure).empty(); }
        if (!threw) return jsti::fail("Corrupt input decoded without an error.", error, capacity);
    }
    return 0;
}

// A read that never completes must still release promptly on cancellation,
// long before the 30-second decode timeout.
int selfTestStalledDecodeCancel(char *error, size_t capacity) {
    ReadState state;
    std::atomic<bool> cancelled{false};
    { std::lock_guard<std::mutex> lock(state.mutex); state.pending = true; }
    std::thread canceller([&] {
        Sleep(50);
        cancelled.store(true);
        { std::lock_guard<std::mutex> lock(state.mutex); }
        state.changed.notify_all();
    });
    const ULONGLONG started = GetTickCount64();
    bool threw = false;
    try { awaitSample(state, cancelled, std::chrono::seconds(decodeTimeoutSeconds)); } catch (const Cancelled &) { threw = true; }
    canceller.join();
    if (!threw || GetTickCount64() - started > 5000) {
        return jsti::fail("Cancelling a stalled decoder read did not release it promptly.", error, capacity);
    }
    return 0;
}

// Full production path against the synthetic engine: the bytes the engine
// hears are exactly the decoded source, with no trailing silence, the final
// packet is the exact remainder and every completion contract holds.

} // namespace jsti::playback::selftest
