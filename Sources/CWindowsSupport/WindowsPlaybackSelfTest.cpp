#include "CWindowsSupport.h"
#include "WindowsPlaybackInternal.hpp"
#include <array>
#include <cstdio>
#include <deque>

// Synthetic checks for the playback engine. A synthetic output engine stands
// in for WASAPI so the production decode/queue/render code runs on machines
// without a speaker; the physical endpoint acceptance lives in the Swift tests
// behind the explicit capability probe.
namespace {
using namespace jsti::playback;

constexpr DWORD waveHeaderSize = 44;
constexpr uint32_t fixtureRate = 24000;
constexpr int16_t fixtureAmplitude = 512; // About -36 dBFS: audible in a test, never loud.
constexpr uint32_t shortFrames = 2400;     // 0.1 s.
constexpr uint32_t longFrames = 48000;     // 2 s.
constexpr DWORD deadline = 15000;

void put16(uint8_t *bytes, uint16_t value) {
    bytes[0] = static_cast<uint8_t>(value); bytes[1] = static_cast<uint8_t>(value >> 8);
}
void put32(uint8_t *bytes, uint32_t value) {
    for (int index = 0; index < 4; ++index) bytes[index] = static_cast<uint8_t>(value >> (8 * index));
}
std::array<uint8_t, waveHeaderSize> waveHeader(uint32_t bytes, uint32_t rate, uint16_t channels) {
    std::array<uint8_t, waveHeaderSize> header{};
    std::memcpy(header.data(), "RIFF", 4); put32(header.data() + 4, bytes + 36);
    std::memcpy(header.data() + 8, "WAVEfmt ", 8); put32(header.data() + 16, 16);
    put16(header.data() + 20, 1); put16(header.data() + 22, channels); put32(header.data() + 24, rate);
    put32(header.data() + 28, rate * channels * 2); put16(header.data() + 32, channels * 2); put16(header.data() + 34, 16);
    std::memcpy(header.data() + 36, "data", 4); put32(header.data() + 40, bytes);
    return header;
}

// A 200 Hz square wave at a low amplitude; deterministic for exact comparisons.
int16_t fixtureSample(uint64_t frame, uint32_t rate) {
    return (frame / std::max<uint32_t>(1, rate / 400)) % 2 ? fixtureAmplitude : static_cast<int16_t>(-fixtureAmplitude);
}

void writeBytes(HANDLE file, const uint8_t *bytes, DWORD count) {
    DWORD written = 0;
    if (!WriteFile(file, bytes, count, &written, nullptr) || written != count) {
        throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Write synthetic playback fixture"};
    }
}

void createWaveFixture(const std::wstring &path, uint32_t rate, uint16_t channels, uint32_t frames) {
    std::string error;
    jsti::Handle file;
    file.value = jsti::createPrivateFileHandle(jsti::utf8(path).c_str(), error);
    if (file.value == INVALID_HANDLE_VALUE) {
        file.value = nullptr;
        throw Failure{E_ACCESSDENIED, "Create synthetic WAV fixture"};
    }
    const uint32_t size = frames * channels * 2;
    const auto header = waveHeader(size, rate, channels);
    writeBytes(file.value, header.data(), static_cast<DWORD>(header.size()));
    std::array<uint8_t, 4096> buffer{};
    uint32_t offset = 0;
    while (offset < frames) {
        const uint32_t count = std::min<uint32_t>(static_cast<uint32_t>(buffer.size()) / (channels * 2u), frames - offset);
        for (uint32_t frame = 0; frame < count; ++frame) {
            const auto sample = static_cast<uint16_t>(fixtureSample(offset + frame, rate));
            for (uint16_t channel = 0; channel < channels; ++channel) put16(buffer.data() + (frame * channels + channel) * 2, sample);
        }
        writeBytes(file.value, buffer.data(), count * channels * 2);
        offset += count;
    }
}

bool matchesFixture(const uint8_t *bytes, size_t count, uint32_t frames) {
    if (count != static_cast<size_t>(frames) * 2) return false;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const uint16_t value = static_cast<uint16_t>(bytes[frame * 2]) | (static_cast<uint16_t>(bytes[frame * 2 + 1]) << 8);
        if (value != static_cast<uint16_t>(fixtureSample(frame, fixtureRate))) return false;
    }
    return true;
}

bool verifyWaveFixture(const std::wstring &path, uint32_t frames) {
    jsti::Handle file;
    file.value = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                             FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (file.value == INVALID_HANDLE_VALUE) { file.value = nullptr; return false; }
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file.value, &size) || static_cast<uint64_t>(size.QuadPart) != waveHeaderSize + uint64_t{frames} * 2) return false;
    const auto expected = waveHeader(frames * 2, fixtureRate, 1);
    std::vector<uint8_t> content(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    if (!ReadFile(file.value, content.data(), static_cast<DWORD>(content.size()), &read, nullptr) || read != content.size()) return false;
    return std::equal(expected.begin(), expected.end(), content.begin()) &&
        matchesFixture(content.data() + waveHeaderSize, content.size() - waveHeaderSize, frames);
}

// A write-open succeeds only once every pinned handle has been released.
bool writable(const std::wstring &path) {
    const HANDLE writer = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
    if (writer == INVALID_HANDLE_VALUE) return false;
    CloseHandle(writer);
    return true;
}

struct PlaybackTestFiles {
    std::wstring root;
    std::vector<std::wstring> files;
    ~PlaybackTestFiles() {
        for (const auto &path : files) DeleteFileW(path.c_str());
        if (!root.empty()) RemoveDirectoryW(root.c_str());
    }
    std::wstring path(const wchar_t *name) {
        auto value = root + L"\\" + name;
        files.push_back(value);
        return value;
    }
};

bool absent(const std::wstring &path) {
    if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES) return false;
    const DWORD code = GetLastError();
    return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND;
}

// Simulated audio engine: a fixed buffer of frames the render thread fills
// through the production RenderOutput contract, and a test-side consumer that
// plays frames out only while started, recording every byte it hears.
struct SyntheticEngine {
    std::mutex mutex;
    std::condition_variable changed;
    jsti::Handle event;
    const UINT32 bufferFrames;
    const size_t frameBytes;
    std::vector<uint8_t> staging;
    std::deque<uint8_t> queue;
    std::vector<uint8_t> heard;
    UINT32 queued = 0;
    bool started = false, acquired = false;
    UINT32 acquiredFrames = 0;
    int starts = 0, stops = 0;
    uint64_t submittedFrames = 0, consumedFrames = 0, packets = 0, largestPacket = 0;
    HRESULT startResult = S_OK;
    HRESULT stopResult = S_OK;
    HRESULT paddingResult = S_OK;
    HANDLE closeReadGateOnStart = nullptr;
    HANDLE startGate = nullptr, startEntered = nullptr;
    REFERENCE_TIME latencyTicks = 0;
    DWORD requestedLatencyMilliseconds = 0;

    SyntheticEngine(UINT32 bufferFrames, size_t frameBytes)
        : bufferFrames(bufferFrames), frameBytes(frameBytes), staging(static_cast<size_t>(bufferFrames) * frameBytes) {
        event.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    }
    HRESULT padding(UINT32 &frames) noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        if (FAILED(paddingResult)) return paddingResult;
        frames = queued;
        return S_OK;
    }
    HRESULT acquire(UINT32 frames, BYTE **data) noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        if (!frames || acquired || frames > bufferFrames - queued) return AUDCLNT_E_BUFFER_TOO_LARGE;
        acquired = true;
        acquiredFrames = frames;
        *data = staging.data();
        return S_OK;
    }
    HRESULT release(UINT32 frames) noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        if (!acquired || (frames && frames != acquiredFrames)) return AUDCLNT_E_INVALID_SIZE;
        acquired = false;
        if (frames) {
            queue.insert(queue.end(), staging.begin(), staging.begin() + static_cast<ptrdiff_t>(frames * frameBytes));
            queued += frames;
            submittedFrames += frames;
            ++packets;
            largestPacket = std::max<uint64_t>(largestPacket, frames);
        }
        changed.notify_all();
        return S_OK;
    }
    HRESULT start() noexcept {
        if (startEntered) SetEvent(startEntered);
        if (startGate && WaitForSingleObject(startGate, deadline) != WAIT_OBJECT_0) return E_ABORT;
        std::lock_guard<std::mutex> lock(mutex);
        if (FAILED(startResult)) return startResult;
        if (started) return AUDCLNT_E_NOT_STOPPED;
        if (closeReadGateOnStart) ResetEvent(closeReadGateOnStart);
        started = true;
        ++starts;
        changed.notify_all();
        return S_OK;
    }
    HRESULT stop() noexcept {
        std::lock_guard<std::mutex> lock(mutex);
        if (FAILED(stopResult)) return stopResult;
        const bool wasStarted = started;
        started = false;
        ++stops;
        changed.notify_all();
        return wasStarted ? S_OK : S_FALSE;
    }
    // Test side: the engine consumes only while started, then asks for more.
    UINT32 consume(UINT32 frames) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!started) return 0;
        const UINT32 count = std::min(frames, queued);
        const auto bytes = static_cast<ptrdiff_t>(static_cast<size_t>(count) * frameBytes);
        heard.insert(heard.end(), queue.begin(), queue.begin() + bytes);
        queue.erase(queue.begin(), queue.begin() + bytes);
        queued -= count;
        consumedFrames += count;
        changed.notify_all();
        SetEvent(event.value);
        return count;
    }
    template<class Predicate> bool waitFor(Predicate predicate, DWORD milliseconds) {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::milliseconds(milliseconds), [&] { return predicate(); });
    }
};

class SyntheticOutput final : public RenderOutput {
    std::shared_ptr<SyntheticEngine> engine;
public:
    explicit SyntheticOutput(std::shared_ptr<SyntheticEngine> engine) : engine(std::move(engine)) {}
    ~SyntheticOutput() override {
        // Releasing the endpoint ends output even when its Stop call failed.
        std::lock_guard<std::mutex> lock(engine->mutex);
        engine->started = false;
        engine->changed.notify_all();
    }
    HANDLE event() const noexcept override { return engine->event.value; }
    UINT32 bufferFrames() const noexcept override { return engine->bufferFrames; }
    HRESULT start() noexcept override { return engine->start(); }
    HRESULT stop() noexcept override { return engine->stop(); }
    HRESULT padding(UINT32 &frames) noexcept override { return engine->padding(frames); }
    HRESULT acquire(UINT32 frames, BYTE **data) noexcept override { return engine->acquire(frames, data); }
    HRESULT release(UINT32 frames) noexcept override { return engine->release(frames); }
    REFERENCE_TIME latency() noexcept override {
        std::lock_guard<std::mutex> lock(engine->mutex);
        return engine->latencyTicks;
    }
    DWORD waitForLatency(HANDLE, DWORD milliseconds) noexcept override {
        std::lock_guard<std::mutex> lock(engine->mutex);
        engine->requestedLatencyMilliseconds += milliseconds;
        return WAIT_TIMEOUT; // Advance only the explicitly modelled device delay.
    }
};

class SyntheticFactory final : public OutputFactory {
    std::shared_ptr<SyntheticEngine> engine;
    FormatSpec target;
public:
    SyntheticFactory(std::shared_ptr<SyntheticEngine> engine, FormatSpec target)
        : engine(std::move(engine)), target(std::move(target)) {}
    std::unique_ptr<RenderOutput> open(Decoder &decoder, FormatSpec &format) override {
        require(decoder.configure(target), "Configure the synthetic decode format");
        format = decoder.format();
        if (format.blockAlign != engine->frameBytes) throw Failure{E_INVALIDARG, "Synthetic engine frame size mismatch"};
        return std::make_unique<SyntheticOutput>(engine);
    }
};

struct RunResult {
    std::mutex mutex;
    std::condition_variable changed;
    JSTIAudioPlayback *job = nullptr;
    int callbacks = 0, status = -2;
    double played = 0;
    bool selfDestroyRejected = false;
    std::string error;
    struct Snapshot {
        int callbacks, status;
        double played;
        bool selfDestroyRejected;
        std::string error;
    };
    Snapshot snapshot() {
        std::lock_guard<std::mutex> lock(mutex);
        return {callbacks, status, played, selfDestroyRejected, error};
    }
    bool wait(DWORD milliseconds) {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::milliseconds(milliseconds), [&] { return callbacks != 0; });
    }
};

void completion(int status, double played, const char *message, void *context) {
    auto &result = *static_cast<RunResult *>(context);
    char selfJoinError[256] = {};
    const bool rejected = jsti_audio_playback_destroy(result.job, selfJoinError, sizeof(selfJoinError)) == -1 &&
        selfJoinError[0];
    std::lock_guard<std::mutex> lock(result.mutex);
    ++result.callbacks;
    result.status = status;
    result.played = played;
    result.selfDestroyRejected = rejected;
    result.error = message ? message : "";
    result.changed.notify_all();
}

// One synthetic playback: engine, completion capture and the owned job.
struct SyntheticRun {
    std::shared_ptr<SyntheticEngine> engine;
    RunResult result;
    JSTIAudioPlayback *job = nullptr;
    ~SyntheticRun() {
        // Never let a failed join strand a callback pointing into this stack.
        // The test owner is never the callback thread, so a persistent join
        // failure violates the lifetime invariant and cannot safely unwind.
        if (job && jsti_audio_playback_destroy(job, nullptr, 0) != 0) std::terminate();
    }

    bool create(const std::wstring &path, const FormatSpec &target, UINT32 bufferFrames, const EngineOptions &options,
                std::string &error) {
        engine = std::make_shared<SyntheticEngine>(bufferFrames, target.blockAlign);
        if (!engine->event.value) { error = "Could not create the synthetic engine event."; return false; }
        char detail[1024] = {};
        job = createPlayback(jsti::utf8(path).c_str(), completion, &result,
                             std::make_unique<SyntheticFactory>(engine, target), options, detail, sizeof(detail));
        if (!job) { error = detail; return false; }
        result.job = job;
        return true;
    }
    bool start(std::string &error) {
        char detail[1024] = {};
        if (jsti_audio_playback_start(job, detail, sizeof(detail)) != 0) { error = detail; return false; }
        return true;
    }
    JSTIAudioPlaybackSnapshot snapshot() const {
        JSTIAudioPlaybackSnapshot value{};
        jsti_audio_playback_snapshot(job, &value);
        return value;
    }
    // Plays the simulated engine out in steps until the completion arrives.
    bool drive(UINT32 framesPerStep, DWORD milliseconds) {
        const ULONGLONG limit = GetTickCount64() + milliseconds;
        while (GetTickCount64() < limit) {
            if (result.wait(0)) return true;
            engine->consume(framesPerStep);
            Sleep(2);
        }
        return result.wait(0);
    }
    bool waitForState(int state, DWORD milliseconds) const {
        const ULONGLONG limit = GetTickCount64() + milliseconds;
        while (GetTickCount64() < limit) {
            if (snapshot().state == state) return true;
            Sleep(2);
        }
        return snapshot().state == state;
    }
    // Destroys now (joins) and reports the native result.
    bool destroy(std::string &error) {
        char detail[1024] = {};
        const int code = jsti_audio_playback_destroy(job, detail, sizeof(detail));
        if (code != 0) { error = detail; return false; }
        job = nullptr;
        return true;
    }
};

bool approximately(double value, double expected, double tolerance = 0.0005) { return std::abs(value - expected) <= tolerance; }

// Fixed queue: wrap across the boundary, partial writes, whole-frame reads,
// capacity refusal and FIFO order under a byte counter pattern.
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
int selfTestSyntheticFinish(const std::wstring &fixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 1200, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    const auto before = run.snapshot();
    if (before.state != statePreparing || before.position_seconds != 0 || before.duration_seconds != -1) {
        return jsti::fail("A created playback did not report the preparing state.", error, capacity);
    }
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    char refused[256] = {};
    if (jsti_audio_playback_start(run.job, refused, sizeof(refused)) != -1 || !refused[0]) {
        return jsti::fail("Audio playback admitted a second start.", error, capacity);
    }
    if (!run.drive(240, deadline)) return jsti::fail("Synthetic playback did not complete.", error, capacity);
    const auto &engine = *run.engine;
    const auto after = run.snapshot();
    if (run.result.snapshot().callbacks != 1 || run.result.snapshot().status != 0 || !run.result.snapshot().error.empty() || !run.result.snapshot().selfDestroyRejected) {
        return jsti::fail("Synthetic playback did not finish with exactly one clean completion: " + run.result.snapshot().error, error, capacity);
    }
    if (!approximately(run.result.snapshot().played, 0.1) || after.state != stateEnded || !approximately(after.position_seconds, 0.1) ||
        !approximately(after.duration_seconds, 0.1)) {
        return jsti::fail("Finished playback did not report the full source position and duration.", error, capacity);
    }
    if (engine.submittedFrames != shortFrames || engine.consumedFrames != shortFrames || engine.queued != 0 ||
        engine.starts != 1 || engine.stops != 1 || engine.packets < 2 || engine.largestPacket > 1200 ||
        !matchesFixture(engine.heard.data(), engine.heard.size(), shortFrames)) {
        return jsti::fail("The engine heard padded, reordered or altered audio.", error, capacity);
    }
    if (jsti_audio_playback_pause(run.job) != 1 || jsti_audio_playback_resume(run.job) != 1) {
        return jsti::fail("Controls after the end of playback were not reported as ignored.", error, capacity);
    }
    if (!run.destroy(detail)) return jsti::fail(detail, error, capacity);
    if (!writable(fixture) || !verifyWaveFixture(fixture, shortFrames)) {
        return jsti::fail("Playback modified its source or kept it pinned after destroy.", error, capacity);
    }
    return 0;
}


struct SignalOnExit {
    HANDLE event;
    ~SignalOnExit() { if (event) SetEvent(event); }
};

// A 100 ms source fits inside a 500 ms output buffer. The production render
// loop must submit only its 2400 real frames and add no synthetic buffer tail.
// The synthetic clock charges only the device latency requested by that loop.
int selfTestShortSourceLargeBuffer(const std::wstring &fixture, char *error, size_t capacity) {
    for (DWORD latency : {DWORD{0}, DWORD{25}}) {
        SyntheticRun run;
        std::string detail;
        if (!run.create(fixture, pcm16Format(fixtureRate, 1), 12000, EngineOptions{}, detail)) {
            return jsti::fail(detail, error, capacity);
        }
        run.engine->latencyTicks = REFERENCE_TIME{latency} * 10000;
        if (!run.start(detail) || !run.drive(2400, deadline)) {
            return jsti::fail("The 100 ms source did not finish in its 500 ms engine buffer: " + detail, error, capacity);
        }
        const auto result = run.result.snapshot();
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        const auto &engine = *run.engine;
        if (result.status != 0 || engine.submittedFrames != shortFrames || engine.consumedFrames != shortFrames ||
            engine.packets != 1 || engine.largestPacket != shortFrames || engine.queued != 0 ||
            !matchesFixture(engine.heard.data(), engine.heard.size(), shortFrames) ||
            engine.requestedLatencyMilliseconds != latency || !approximately(result.played, 0.1)) {
            return jsti::fail("Short playback manufactured a tail or a delay beyond its modelled device latency.", error, capacity);
        }
        // Source duration 100 ms + the requested 0/25 ms device latency; no
        // 400 ms buffer-fill/drain overhead is charged to the synthetic clock.
    }
    return 0;
}

// Cancel versus a reserved Start: never acknowledge silence while Start can
// still return and make sound. A never-started cancellation is permanently quiet.
int selfTestOutputAcknowledgement(const std::wstring &fixture, char *error, size_t capacity) {
    jsti::Handle gate, entered;
    gate.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!gate.value || !entered.value) return jsti::fail("Could not create output acknowledgement gates.", error, capacity);
    SyntheticRun run;
    SignalOnExit unblock{gate.value};
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 12000, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    run.engine->startGate = gate.value;
    run.engine->startEntered = entered.value;
    if (!run.start(detail) || WaitForSingleObject(entered.value, deadline) != WAIT_OBJECT_0) {
        return jsti::fail("The synthetic Start was not reserved.", error, capacity);
    }
    jsti_audio_playback_cancel(run.job);
    if (run.snapshot().output_state != outputStarted) {
        return jsti::fail("Cancellation acknowledged quiet while a reserved Start was still in flight.", error, capacity);
    }
    SetEvent(gate.value);
    if (!run.result.wait(deadline) || run.snapshot().output_state != outputStopped) {
        return jsti::fail("The render thread did not acknowledge stopped output after cancellation.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        if (run.engine->started) return jsti::fail("Stopped output remained audible.", error, capacity);
    }
    if (!run.destroy(detail)) return jsti::fail(detail, error, capacity);
    SyntheticRun neverStarted;
    if (!neverStarted.create(fixture, pcm16Format(fixtureRate, 1), 12000, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    jsti_audio_playback_cancel(neverStarted.job);
    if (neverStarted.snapshot().output_state != outputNeverStarted || neverStarted.start(detail) ||
        neverStarted.result.wait(0) || neverStarted.engine->starts != 0) {
        return jsti::fail("A never-started quiet acknowledgement allowed a later native Start.", error, capacity);
    }
    return 0;
}

// Stall an actual MF source read after output begins, then fail the production
// render path. Witness awaitSample returning for the render result before the
// test releases the codec gate; a ready/read callback cannot mask the old 30 s bug.
int selfTestRenderFailureWakesReader(const std::wstring &fixture, bool stopFails, char *error, size_t capacity) {
    jsti::Handle gate, entered;
    gate.value = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!gate.value || !entered.value) return jsti::fail("Could not create the stalled decoder gates.", error, capacity);
    SyntheticRun run;
    SignalOnExit unblock{gate.value};
    EngineOptions options;
    options.readGate = gate.value;
    options.readGateEntered = entered.value;
    options.eventTimeout = 5000;
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 2400, options, detail)) return jsti::fail(detail, error, capacity);
    run.engine->closeReadGateOnStart = gate.value;
    const auto state = playbackReadState(run.job);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    bool stalled = false;
    const ULONGLONG until = GetTickCount64() + 5000;
    while (GetTickCount64() < until) {
        run.engine->consume(2400);
        if (WaitForSingleObject(entered.value, 0) == WAIT_OBJECT_0) {
            std::lock_guard<std::mutex> lock(state->mutex);
            stalled = state->pending && !state->ready;
        }
        if (stalled) break;
        Sleep(2);
    }
    if (!stalled) return jsti::fail("The actual decoder did not reach its gated pending read.", error, capacity);
    {
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        run.engine->paddingResult = AUDCLNT_E_DEVICE_INVALIDATED;
        if (stopFails) run.engine->stopResult = E_FAIL;
    }
    SetEvent(run.engine->event.value);
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        if (!state->changed.wait_for(lock, std::chrono::seconds(2), [&] { return state->renderEndObserved; })) {
            return jsti::fail("Render failure did not wake the stalled pending read before codec release.", error, capacity);
        }
    }
    if (run.snapshot().output_state != (stopFails ? outputStarted : outputStopped)) {
        return jsti::fail(stopFails ? "A failed Stop falsely acknowledged quiet before endpoint release."
                                   : "Output was not acknowledged quiet before the stalled codec was released.", error, capacity);
    }
    SetEvent(gate.value); // Decoder teardown may now drain its native callback.
    if (!run.result.wait(5000)) return jsti::fail("The awakened render failure did not complete promptly.", error, capacity);
    const auto result = run.result.snapshot();
    if (result.status != -1 || result.error.find("disconnected") == std::string::npos || result.callbacks != 1) {
        return jsti::fail("The stalled-read wake lost the original render error: " + result.error, error, capacity);
    }
    if (run.snapshot().output_state != outputStopped) {
        return jsti::fail("Releasing the failed endpoint did not acknowledge quiet.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        if (run.engine->started) return jsti::fail("Output survived release of its endpoint.", error, capacity);
    }
    return 0;
}

// Pause freezes the engine and the position; a pause longer than the event
// timeout is not a failure; resume continues from the same frames.
int selfTestSyntheticPauseResume(const std::wstring &longFixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    EngineOptions options;
    options.eventTimeout = 200;
    if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, options, detail)) return jsti::fail(detail, error, capacity);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    if (!run.waitForState(statePlaying, deadline)) return jsti::fail("Synthetic playback never started playing.", error, capacity);
    for (int step = 0; step < 6; ++step) { run.engine->consume(480); Sleep(5); }
    if (jsti_audio_playback_pause(run.job) != 0) return jsti::fail("Pause was not accepted while playing.", error, capacity);
    if (!run.engine->waitFor([&] { return run.engine->stops == 1 && !run.engine->started; }, deadline) ||
        !run.waitForState(statePaused, deadline)) {
        return jsti::fail("Pause did not stop the engine.", error, capacity);
    }
    const double pausedAt = run.snapshot().position_seconds;
    const uint64_t heardAtPause = run.engine->consumedFrames;
    if (pausedAt <= 0 || !approximately(pausedAt, static_cast<double>(heardAtPause) / fixtureRate)) {
        return jsti::fail("The paused position does not match the frames the engine consumed.", error, capacity);
    }
    Sleep(500); // Longer than the event timeout: a paused engine must not fail.
    if (run.engine->consume(480) != 0 || run.result.wait(0) || run.snapshot().state != statePaused ||
        run.snapshot().position_seconds != pausedAt || jsti_audio_playback_pause(run.job) != 0) {
        return jsti::fail("A paused playback advanced, consumed audio, failed or refused a repeated pause.", error, capacity);
    }
    if (jsti_audio_playback_resume(run.job) != 0 ||
        !run.engine->waitFor([&] { return run.engine->starts == 2 && run.engine->started; }, deadline) ||
        !run.waitForState(statePlaying, deadline)) {
        return jsti::fail("Resume did not restart the engine.", error, capacity);
    }
    double last = pausedAt;
    for (int step = 0; step < 4; ++step) {
        run.engine->consume(480);
        Sleep(5);
        const double position = run.snapshot().position_seconds;
        if (position < last) return jsti::fail("The position moved backwards after resume.", error, capacity);
        last = position;
    }
    if (!run.drive(480, deadline)) return jsti::fail("Resumed playback did not complete.", error, capacity);
    if (run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 2.0) || run.engine->consumedFrames != longFrames ||
        !matchesFixture(run.engine->heard.data(), run.engine->heard.size(), longFrames)) {
        return jsti::fail("Playback across a pause lost, duplicated or altered audio: " + run.result.snapshot().error, error, capacity);
    }
    return 0;
}

int selfTestSyntheticCancelWhilePaused(const std::wstring &longFixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    if (!run.waitForState(statePlaying, deadline)) return jsti::fail("Playback never started before the pause.", error, capacity);
    for (int step = 0; step < 4; ++step) { run.engine->consume(480); Sleep(5); }
    jsti_audio_playback_pause(run.job);
    if (!run.waitForState(statePaused, deadline)) return jsti::fail("Pause was not acknowledged.", error, capacity);
    const double pausedAt = run.snapshot().position_seconds;
    jsti_audio_playback_cancel(run.job);
    if (!run.result.wait(deadline)) return jsti::fail("Cancelling a paused playback did not complete.", error, capacity);
    if (run.result.snapshot().status != 1 || run.result.snapshot().callbacks != 1 || !approximately(run.result.snapshot().played, pausedAt) ||
        run.engine->consumedFrames != static_cast<uint64_t>(pausedAt * fixtureRate + 0.5) ||
        run.snapshot().state != stateEnded) {
        return jsti::fail("Cancelling while paused misreported the heard position.", error, capacity);
    }
    return 0;
}

// End of stream races: the whole file is queued before the engine starts, so
// pausing and cancelling happen while the engine drains its buffer. Only the
// frames the engine consumed count as heard.
int selfTestSyntheticDrainRaces(const std::wstring &fixture, char *error, size_t capacity) {
    {
        SyntheticRun run;
        std::string detail;
        if (!run.create(fixture, pcm16Format(fixtureRate, 1), 4800, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.engine->waitFor([&] { return run.engine->submittedFrames == shortFrames && run.engine->started; }, deadline)) {
            return jsti::fail("The short file was not pre-rolled in full before the engine started.", error, capacity);
        }
        run.engine->consume(1000);
        jsti_audio_playback_pause(run.job);
        if (!run.waitForState(statePaused, deadline) || !approximately(run.snapshot().position_seconds, 1000.0 / fixtureRate)) {
            return jsti::fail("Pausing during the drain misreported the position.", error, capacity);
        }
        jsti_audio_playback_resume(run.job);
        if (!run.waitForState(statePlaying, deadline) || !run.drive(480, deadline)) {
            return jsti::fail("Resuming during the drain did not finish playback.", error, capacity);
        }
        if (run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 0.1) || run.engine->consumedFrames != shortFrames) {
            return jsti::fail("A drain interrupted by pause lost audio.", error, capacity);
        }
    }
    {
        SyntheticRun run;
        std::string detail;
        if (!run.create(fixture, pcm16Format(fixtureRate, 1), 4800, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.engine->waitFor([&] { return run.engine->submittedFrames == shortFrames && run.engine->started; }, deadline)) {
            return jsti::fail("The short file was not pre-rolled before cancellation.", error, capacity);
        }
        run.engine->consume(1000);
        run.engine->waitFor([&] { return false; }, 30); // Let the engine observe the consumption.
        jsti_audio_playback_cancel(run.job);
        if (!run.result.wait(deadline)) return jsti::fail("Cancelling during the drain did not complete.", error, capacity);
        // 2400 frames were queued and 1000 heard: the counterexample from the
        // review must report exactly 1000 heard frames, not the queued total.
        if (run.result.snapshot().status != 1 || !approximately(run.result.snapshot().played, 1000.0 / fixtureRate) || run.engine->consumedFrames != 1000) {
            return jsti::fail("Cancelling during the drain counted queued frames as heard.", error, capacity);
        }
    }
    return 0;
}

int selfTestSyntheticFailures(const std::wstring &longFixture, char *error, size_t capacity) {
    {
        SyntheticRun run;
        std::string detail;
        EngineOptions options;
        options.eventTimeout = 200;
        if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, options, detail)) return jsti::fail(detail, error, capacity);
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.waitForState(statePlaying, deadline)) return jsti::fail("Playback never started before the silent engine check.", error, capacity);
        // The engine never asks for audio again: a started stream that stops
        // signalling is an explicit failure, never a hang.
        if (!run.result.wait(deadline) || run.result.snapshot().status != -1 ||
            run.result.snapshot().error.find("stopped requesting audio") == std::string::npos || run.snapshot().state != stateEnded) {
            return jsti::fail("A silent engine did not fail with the event timeout: " + run.result.snapshot().error, error, capacity);
        }
    }
    {
        SyntheticRun run;
        std::string detail;
        if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
        run.engine->startResult = AUDCLNT_E_DEVICE_INVALIDATED;
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.result.wait(deadline) || run.result.snapshot().status != -1 || run.result.snapshot().played != 0 ||
            run.result.snapshot().error.find("disconnected") == std::string::npos) {
            return jsti::fail("A device failure at start was not reported: " + run.result.snapshot().error, error, capacity);
        }
    }
    return 0;
}

int selfTestSyntheticPauseBeforeStart(const std::wstring &fixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 1200, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    if (jsti_audio_playback_pause(run.job) != 0) return jsti::fail("Pause before start was refused.", error, capacity);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    if (!run.waitForState(statePaused, deadline) || run.engine->starts != 0 || run.snapshot().position_seconds != 0 ||
        run.engine->submittedFrames == 0) {
        return jsti::fail("A pause requested before start did not hold the pre-rolled engine.", error, capacity);
    }
    jsti_audio_playback_resume(run.job);
    if (!run.drive(240, deadline) || run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 0.1) || run.engine->starts != 1) {
        return jsti::fail("Resuming a playback paused before start did not play it out.", error, capacity);
    }
    return 0;
}

int selfTestLifecycle(const std::wstring &fixture, const std::wstring &tinyFixture, char *error, size_t capacity) {
    char detail[1024] = {};
    const std::string input = jsti::utf8(fixture);
    auto unexpected = [](int, double, const char *, void *context) { *static_cast<bool *>(context) = true; };
    bool called = false;
    if (jsti_audio_playback_create(input.c_str(), nullptr, &called, detail, sizeof(detail)) || !detail[0]) {
        return jsti::fail("Audio playback accepted a missing callback.", error, capacity);
    }
    const char *invalid[] = {"relative.wav", "", "C:\\", "C:\\folder\\..\\audio.wav", "\xc3\x28"};
    for (const char *path : invalid) {
        detail[0] = 0;
        if (jsti_audio_playback_create(path, unexpected, &called, detail, sizeof(detail)) || !detail[0]) {
            return jsti::fail("Audio playback accepted an unsafe input path.", error, capacity);
        }
    }
    detail[0] = 0;
    if (jsti_audio_playback_create((input + ".missing").c_str(), unexpected, &called, detail, sizeof(detail)) || !detail[0]) {
        return jsti::fail("Audio playback accepted a missing input file.", error, capacity);
    }
    JSTIAudioPlaybackSnapshot snapshot{};
    if (jsti_audio_playback_snapshot(nullptr, &snapshot) != -1 || jsti_audio_playback_pause(nullptr) != -1 ||
        jsti_audio_playback_resume(nullptr) != -1 || jsti_audio_playback_destroy(nullptr, detail, sizeof(detail)) != 0) {
        return jsti::fail("Null playback handles were not rejected consistently.", error, capacity);
    }
    // Cancelled before start: refused synchronously, no callback, clean destroy,
    // and the pin is released without the file ever being read by a codec.
    std::memcpy(detail, "stale", 6);
    auto *cancelled = jsti_audio_playback_create(input.c_str(), unexpected, &called, detail, sizeof(detail));
    if (!cancelled || detail[0]) return jsti::fail("Audio playback creation failed or left a stale error.", error, capacity);
    if (writable(fixture)) return jsti::fail("A created playback did not pin its source.", error, capacity);
    jsti_audio_playback_cancel(cancelled);
    const int start = jsti_audio_playback_start(cancelled, detail, sizeof(detail));
    const int destroyed = jsti_audio_playback_destroy(cancelled, detail, sizeof(detail));
    if (start != -1 || destroyed != 0 || called || !writable(fixture)) {
        return jsti::fail("Cancelled-before-start audio playback ran, invoked its callback or kept its pin.", error, capacity);
    }
    // A 10 ms file completes about as fast as start returns; the completion
    // still arrives exactly once and destroy still joins cleanly.
    for (int attempt = 0; attempt < 3; ++attempt) {
        SyntheticRun run;
        std::string failure;
        if (!run.create(tinyFixture, pcm16Format(fixtureRate, 1), 480, EngineOptions{}, failure)) return jsti::fail(failure, error, capacity);
        if (!run.start(failure)) return jsti::fail(failure, error, capacity);
        if (!run.drive(240, deadline) || run.result.snapshot().callbacks != 1 || run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 0.01) ||
            !run.result.snapshot().selfDestroyRejected) {
            return jsti::fail("An immediately completing playback broke the exactly-once contract.", error, capacity);
        }
        if (!run.destroy(failure)) return jsti::fail(failure, error, capacity);
        if (run.result.snapshot().callbacks != 1) return jsti::fail("A completion arrived after destroy.", error, capacity);
    }
    return 0;
}
} // namespace

int jsti_audio_playback_self_test(char *error, size_t capacity) {
    try {
        if (selfTestRing(error, capacity) || selfTestStalledDecodeCancel(error, capacity)) return -1;
        wchar_t temporary[32768] = {};
        const DWORD count = GetTempPathW(static_cast<DWORD>(std::size(temporary)), temporary);
        GUID guid{};
        wchar_t identifier[40] = {};
        if (!count || count >= std::size(temporary) || FAILED(CoCreateGuid(&guid)) ||
            !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
            return jsti::fail("Could not create unique playback test paths.", error, capacity);
        }
        const std::wstring root = std::wstring(temporary) + L"JustSpeakToIt-playback-test-" + identifier;
        if (!absent(root)) return jsti::fail("Playback test path already exists.", error, capacity);
        char detail[1024] = {};
        if (jsti_private_directory_prepare(jsti::utf8(root).c_str(), detail, sizeof(detail)) != 0) {
            return jsti::fail(detail, error, capacity);
        }
        PlaybackTestFiles files;
        files.root = root;
        const auto fixture = files.path(L"tone-24khz.wav");
        const auto longFixture = files.path(L"tone-2s-24khz.wav");
        const auto tinyFixture = files.path(L"tone-10ms-24khz.wav");
        const auto stalledFixture = files.path(L"tone-stalled-30s-24khz.wav");
        const auto corrupt = files.path(L"corrupt.wav");
        createWaveFixture(fixture, fixtureRate, 1, shortFrames);
        createWaveFixture(longFixture, fixtureRate, 1, longFrames);
        createWaveFixture(tinyFixture, fixtureRate, 1, 240);
        createWaveFixture(stalledFixture, fixtureRate, 1, fixtureRate * 30);
        {
            std::string failure;
            jsti::Handle file;
            file.value = jsti::createPrivateFileHandle(jsti::utf8(corrupt).c_str(), failure);
            if (file.value == INVALID_HANDLE_VALUE) { file.value = nullptr; return jsti::fail(failure, error, capacity); }
            const uint8_t junk[] = {1, 2, 3, 4, 5, 6};
            writeBytes(file.value, junk, sizeof(junk));
        }
        if (selfTestSourceValidation(fixture, root, error, capacity) ||
            selfTestDecoder(fixture, longFixture, corrupt, error, capacity) ||
            selfTestSyntheticFinish(fixture, error, capacity) ||
            selfTestShortSourceLargeBuffer(fixture, error, capacity) ||
            selfTestOutputAcknowledgement(fixture, error, capacity) ||
            selfTestRenderFailureWakesReader(stalledFixture, false, error, capacity) ||
            selfTestRenderFailureWakesReader(stalledFixture, true, error, capacity) ||
            selfTestSyntheticPauseResume(longFixture, error, capacity) ||
            selfTestSyntheticCancelWhilePaused(longFixture, error, capacity) ||
            selfTestSyntheticDrainRaces(fixture, error, capacity) ||
            selfTestSyntheticFailures(longFixture, error, capacity) ||
            selfTestSyntheticPauseBeforeStart(fixture, error, capacity) ||
            selfTestLifecycle(fixture, tinyFixture, error, capacity)) return -1;
        if (!verifyWaveFixture(fixture, shortFrames) || !verifyWaveFixture(longFixture, longFrames)) {
            return jsti::fail("A playback self-test modified its synthetic source.", error, capacity);
        }
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const Failure &failure) {
        return jsti::fail(describe(failure), error, capacity);
    } catch (const Cancelled &) {
        return jsti::fail("Audio playback self-test was cancelled unexpectedly.", error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("Audio playback self-test could not allocate its state.", error, capacity);
    }
}
