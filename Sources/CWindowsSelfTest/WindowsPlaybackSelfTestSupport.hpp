// Shared fixture for the playback self-test files: WAVE fixtures on disk, a
// synthetic output engine standing in for WASAPI and a run harness.
#pragma once

#include "CWindowsSelfTest.h"
#include "CWindowsSupport.h"
#include "../CWindowsSupport/WindowsPlaybackInternal.hpp"
#include <array>
#include <cstdio>
#include <deque>

namespace jsti::playback::selftest {
using namespace jsti::playback;

constexpr DWORD waveHeaderSize = 44;
constexpr uint32_t fixtureRate = 24000;
constexpr int16_t fixtureAmplitude = 512; // About -36 dBFS: audible in a test, never loud.
constexpr uint32_t shortFrames = 2400;     // 0.1 s.
constexpr uint32_t longFrames = 48000;     // 2 s.
constexpr DWORD deadline = 15000;

inline void put16(uint8_t *bytes, uint16_t value) {
    bytes[0] = static_cast<uint8_t>(value); bytes[1] = static_cast<uint8_t>(value >> 8);
}
inline void put32(uint8_t *bytes, uint32_t value) {
    for (int index = 0; index < 4; ++index) bytes[index] = static_cast<uint8_t>(value >> (8 * index));
}
inline std::array<uint8_t, waveHeaderSize> waveHeader(uint32_t bytes, uint32_t rate, uint16_t channels) {
    std::array<uint8_t, waveHeaderSize> header{};
    std::memcpy(header.data(), "RIFF", 4); put32(header.data() + 4, bytes + 36);
    std::memcpy(header.data() + 8, "WAVEfmt ", 8); put32(header.data() + 16, 16);
    put16(header.data() + 20, 1); put16(header.data() + 22, channels); put32(header.data() + 24, rate);
    put32(header.data() + 28, rate * channels * 2); put16(header.data() + 32, channels * 2); put16(header.data() + 34, 16);
    std::memcpy(header.data() + 36, "data", 4); put32(header.data() + 40, bytes);
    return header;
}

// A 200 Hz square wave at a low amplitude; deterministic for exact comparisons.
inline int16_t fixtureSample(uint64_t frame, uint32_t rate) {
    return (frame / std::max<uint32_t>(1, rate / 400)) % 2 ? fixtureAmplitude : static_cast<int16_t>(-fixtureAmplitude);
}

inline void writeBytes(HANDLE file, const uint8_t *bytes, DWORD count) {
    DWORD written = 0;
    if (!WriteFile(file, bytes, count, &written, nullptr) || written != count) {
        throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Write synthetic playback fixture"};
    }
}

inline void createWaveFixture(const std::wstring &path, uint32_t rate, uint16_t channels, uint32_t frames) {
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

inline bool matchesFixture(const uint8_t *bytes, size_t count, uint32_t frames) {
    if (count != static_cast<size_t>(frames) * 2) return false;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const uint16_t value = static_cast<uint16_t>(bytes[frame * 2]) | (static_cast<uint16_t>(bytes[frame * 2 + 1]) << 8);
        if (value != static_cast<uint16_t>(fixtureSample(frame, fixtureRate))) return false;
    }
    return true;
}

inline bool verifyWaveFixture(const std::wstring &path, uint32_t frames) {
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
inline bool writable(const std::wstring &path) {
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

inline bool absent(const std::wstring &path) {
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

inline void completion(int status, double played, const char *message, void *context) {
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

inline bool approximately(double value, double expected, double tolerance = 0.0005) { return std::abs(value - expected) <= tolerance; }

// Fixed queue: wrap across the boundary, partial writes, whole-frame reads,
// capacity refusal and FIFO order under a byte counter pattern.

// Scenarios (WindowsPlaybackSourceSelfTest.cpp, WindowsPlaybackRenderSelfTest.cpp).
int selfTestRing(char *error, size_t capacity);
int selfTestSourceValidation(const std::wstring &fixture, const std::wstring &root, char *error, size_t capacity);
int selfTestDecoder(const std::wstring &fixture, const std::wstring &longFixture, const std::wstring &corrupt, char *error, size_t capacity);
int selfTestStalledDecodeCancel(char *error, size_t capacity);
int selfTestSyntheticFinish(const std::wstring &fixture, char *error, size_t capacity);
int selfTestShortSourceLargeBuffer(const std::wstring &fixture, char *error, size_t capacity);
int selfTestOutputAcknowledgement(const std::wstring &fixture, char *error, size_t capacity);
int selfTestRenderFailureWakesReader(const std::wstring &fixture, bool stopFails, char *error, size_t capacity);
int selfTestSyntheticPauseResume(const std::wstring &longFixture, char *error, size_t capacity);
int selfTestSyntheticCancelWhilePaused(const std::wstring &longFixture, char *error, size_t capacity);
int selfTestSyntheticDrainRaces(const std::wstring &fixture, char *error, size_t capacity);
int selfTestSyntheticFailures(const std::wstring &longFixture, char *error, size_t capacity);
int selfTestSyntheticPauseBeforeStart(const std::wstring &fixture, char *error, size_t capacity);
int selfTestLifecycle(const std::wstring &fixture, const std::wstring &tinyFixture, char *error, size_t capacity);

} // namespace jsti::playback::selftest
