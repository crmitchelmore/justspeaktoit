#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <avrt.h>
#include <array>
#include <atomic>
#include <future>
#include <mutex>
#include <memory>
#include <stdexcept>
#include <new>
#include <thread>
#include <vector>

namespace {
// Identifies callbacks on both capture and writer threads without shared mutable
// thread IDs. A callback must never join its own capture/writer lifecycle.
thread_local const JSTICapture *activeCaptureCallback = nullptr;
class CaptureCallbackScope {
    const JSTICapture *previous;
public:
    explicit CaptureCallbackScope(const JSTICapture *capture)
        : previous(activeCaptureCallback) { activeCaptureCallback = capture; }
    ~CaptureCallbackScope() { activeCaptureCallback = previous; }
};

// One producer and one consumer. Slots remain owned by the consumer until its
// borrowed-pointer callback returns. No allocation, mutex or disk I/O in push.
class PCMFrameRing {
public:
    static constexpr size_t frameSamples = 1600;
    static constexpr size_t capacity = 128; // 12.8 seconds, about 400 KiB.
    struct Frame { std::array<int16_t, frameSamples> samples{}; size_t count = 0; };
private:
    std::array<Frame, capacity> slots{};
    alignas(64) std::atomic<size_t> written{0};
    alignas(64) std::atomic<size_t> consumed{0};
public:
    static_assert(std::atomic<size_t>::is_always_lock_free, "Capture indices must be lock-free.");
    bool push(const int16_t *source, size_t count) noexcept {
        if (!count || count > frameSamples) return false;
        const size_t write = written.load(std::memory_order_relaxed);
        if (write - consumed.load(std::memory_order_acquire) >= capacity) return false;
        Frame &slot = slots[write % capacity];
        if (source) std::copy_n(source, count, slot.samples.data());
        else std::fill_n(slot.samples.data(), count, 0);
        slot.count = count;
        written.store(write + 1, std::memory_order_release);
        return true;
    }
    const Frame *front() const noexcept {
        const size_t read = consumed.load(std::memory_order_relaxed);
        if (read == written.load(std::memory_order_acquire)) return nullptr;
        return &slots[read % capacity];
    }
    void pop() noexcept {
        consumed.store(consumed.load(std::memory_order_relaxed) + 1, std::memory_order_release);
    }
};

class BufferedAudioWriter {
    enum class Failure { none, overflow, callback, wake, wait };
    // Heap allocation avoids exhausting the Windows capture thread's stack.
    std::unique_ptr<PCMFrameRing> ring = std::make_unique<PCMFrameRing>();
    jsti::Handle available;
    std::thread worker;
    std::atomic<bool> closed{false};
    std::atomic<Failure> failure{Failure::none};
    JSTIAudioCallback callback;
    void *context;
    const JSTICapture *owner;

    void fail(Failure value) noexcept {
        auto expected = Failure::none;
        failure.compare_exchange_strong(expected, value, std::memory_order_relaxed);
    }
    void run() noexcept {
        while (true) {
            if (const auto *frame = ring->front()) {
                try {
                    CaptureCallbackScope scope(owner);
                    callback(frame->samples.data(), frame->count, context);
                } catch (...) {
                    fail(Failure::callback);
                    return;
                }
                ring->pop();
                continue;
            }
            // Re-read the ring after acquiring close: a final publication can
            // race the first empty check, but always precedes producer close.
            if (closed.load(std::memory_order_acquire)) {
                if (ring->front()) continue;
                return;
            }
            // A bounded wait also permits shutdown if signalling itself fails.
            const DWORD result = WaitForSingleObject(available.value, 100);
            if (result != WAIT_OBJECT_0 && result != WAIT_TIMEOUT) {
                fail(Failure::wait);
                return;
            }
        }
    }
public:
    BufferedAudioWriter(JSTIAudioCallback callback, void *context, const JSTICapture *owner = nullptr)
        : callback(callback), context(context), owner(owner) {
        available.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!available.value) throw std::runtime_error("Could not create the audio writer event.");
        worker = std::thread(&BufferedAudioWriter::run, this);
    }
    ~BufferedAudioWriter() { finish(); }
    bool append(const int16_t *source, size_t count) noexcept {
        if (closed.load(std::memory_order_relaxed) || failure.load(std::memory_order_relaxed) != Failure::none) {
            return false;
        }
        if (!ring->push(source, count)) { fail(Failure::overflow); return false; }
        if (!SetEvent(available.value)) { fail(Failure::wake); return false; }
        return true;
    }
    void finish() {
        if (!closed.exchange(true, std::memory_order_release) && !SetEvent(available.value)) fail(Failure::wake);
        if (worker.joinable()) worker.join();
    }
    const char *error() const noexcept {
        switch (failure.load(std::memory_order_relaxed)) {
        case Failure::none: return nullptr;
        case Failure::overflow: return "The recording writer could not keep up. Recording stopped to avoid silently losing audio.";
        case Failure::callback: return "The recording writer callback failed. Recorded audio may be incomplete.";
        case Failure::wake: return "Signalling the recording writer failed.";
        case Failure::wait: return "Waiting for recording data failed.";
        }
        return "The recording writer failed.";
    }
};

class Frames {
    std::array<int16_t, 1600> samples{};
    size_t used = 0;
    JSTIAudioCallback callback;
    void *context;
public:
    Frames(JSTIAudioCallback callback, void *context) : callback(callback), context(context) {}
    void append(const int16_t *source, size_t count) {
        while (count) {
            const size_t copied = std::min(count, samples.size() - used);
            if (source) std::copy_n(source, copied, samples.data() + used);
            else std::fill_n(samples.data() + used, copied, 0);
            used += copied;
            count -= copied;
            if (source) source += copied;
            if (used == samples.size()) flush();
        }
    }
    void flush() {
        if (used) { callback(samples.data(), used, context); used = 0; }
    }
};

struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};
struct Scheduling {
    DWORD index = 0;
    HANDLE handle = AvSetMmThreadCharacteristicsW(L"Audio", &index);
    ~Scheduling() { if (handle) AvRevertMmThreadCharacteristics(handle); }
};

std::string audioError(const char *operation, HRESULT result) {
    return jsti::systemError(operation, static_cast<DWORD>(result));
}
}

struct JSTICapture {
    JSTIAudioCallback callback;
    JSTIAudioErrorCallback errorCallback;
    void *context;
    jsti::Handle stop;
    std::thread worker;
    std::mutex failureMutex;
    std::string failure;

    JSTICapture(JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback, void *context)
        : callback(callback), errorCallback(errorCallback), context(context) {}

    void run(std::promise<std::string> ready) {
        bool announced = false;
        auto report = [&](const std::string &message) {
            if (!announced) { ready.set_value(message); announced = true; }
            else {
                { std::lock_guard<std::mutex> lock(failureMutex); failure = message; }
                if (errorCallback) {
                    CaptureCallbackScope scope(this);
                    try { errorCallback(message.c_str(), context); } catch (...) { /* Never cross the C ABI. */ }
                }
            }
        };
        try {
            Apartment apartment;
            if (FAILED(apartment.result)) { report(audioError("Initializing microphone COM", apartment.result)); return; }
            jsti::COM<IMMDeviceEnumerator> enumerator;
            HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator.value));
            if (FAILED(result)) { report(audioError("Finding microphones", result)); return; }
            jsti::COM<IMMDevice> device;
            result = enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications, &device.value);
            if (FAILED(result)) { report(audioError("Opening the default communications microphone", result)); return; }
            jsti::COM<IAudioClient> client;
            result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void **>(&client.value));
            if (FAILED(result)) { report(audioError("Activating microphone", result)); return; }
            WAVEFORMATEX format{};
            format.wFormatTag = WAVE_FORMAT_PCM;
            format.nChannels = 1;
            format.nSamplesPerSec = 16000;
            format.wBitsPerSample = 16;
            format.nBlockAlign = 2;
            format.nAvgBytesPerSec = 32000;
            // The Windows audio engine performs channel/sample-rate conversion;
            // no Swift allocations or hand-written low-quality resampler here.
            result = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                2000000, 0, &format, nullptr);
            if (FAILED(result)) { report(audioError("Configuring 16 kHz PCM microphone capture", result)); return; }
            jsti::Handle available;
            available.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!available.value) { report(jsti::systemError("Creating microphone event")); return; }
            result = client->SetEventHandle(available.value);
            if (FAILED(result)) { report(audioError("Registering microphone event", result)); return; }
            UINT32 capacity = 0;
            result = client->GetBufferSize(&capacity);
            // An unexpected driver allocation must never cause unbounded growth.
            if (FAILED(result) || capacity == 0 || capacity > 160000) {
                report("The microphone driver returned an invalid or excessive capture buffer."); return;
            }
            std::vector<int16_t> packet(capacity);
            BufferedAudioWriter writer(callback, context, this);
            auto enqueue = [](const int16_t *samples, size_t count, void *value) {
                static_cast<BufferedAudioWriter *>(value)->append(samples, count);
            };
            Frames frames(enqueue, &writer);
            jsti::COM<IAudioCaptureClient> reader;
            result = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void **>(&reader.value));
            if (FAILED(result)) { report(audioError("Opening microphone capture stream", result)); return; }
            Scheduling scheduling;
            // MMCSS is an optimisation. Capture still works at normal priority
            // when the scheduler service is unavailable or disabled by policy.
            result = client->Start();
            if (FAILED(result)) { report(audioError("Starting microphone", result)); return; }
            ready.set_value({});
            announced = true;
            bool firstPacket = true;
            std::string streamFailure;
            auto drain = [&]() -> bool {
                UINT32 next = 0;
                while (true) {
                    HRESULT hr = reader->GetNextPacketSize(&next);
                    if (FAILED(hr)) { streamFailure = audioError("Reading microphone packet size", hr); return false; }
                    if (!next) return true;
                    BYTE *data = nullptr;
                    UINT32 count = 0;
                    DWORD flags = 0;
                    hr = reader->GetBuffer(&data, &count, &flags, nullptr, nullptr);
                    if (FAILED(hr)) { streamFailure = audioError("Reading microphone packet", hr); return false; }
                    if (!count) return true;
                    if (count > capacity) {
                        reader->ReleaseBuffer(count);
                        streamFailure = "The microphone packet exceeded its negotiated buffer capacity.";
                        return false;
                    }
                    const bool silence = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                    if (!silence && !data) {
                        reader->ReleaseBuffer(count);
                        streamFailure = "The microphone returned an empty audio packet.";
                        return false;
                    }
                    if (!silence) std::memcpy(packet.data(), data, count * sizeof(int16_t));
                    hr = reader->ReleaseBuffer(count);
                    if (FAILED(hr)) { streamFailure = audioError("Releasing microphone packet", hr); return false; }
                    if (!firstPacket && (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY)) {
                        streamFailure = "The microphone lost audio frames. Recording stopped to avoid an incomplete transcript.";
                        return false;
                    }
                    firstPacket = false;
                    // Release the driver-owned buffer before entering Swift.
                    frames.append(silence ? nullptr : packet.data(), count);
                    if (const char *error = writer.error()) { streamFailure = error; return false; }
                }
            };
            HANDLE events[] = {stop.value, available.value};
            while (true) {
                const DWORD wait = WaitForMultipleObjects(2, events, FALSE, 5000);
                if (wait == WAIT_OBJECT_0) break;
                if (wait == WAIT_OBJECT_0 + 1) { if (!drain()) break; }
                else {
                    streamFailure = wait == WAIT_TIMEOUT ? "The microphone stopped producing audio for five seconds."
                                                        : jsti::systemError("Waiting for microphone audio");
                    break;
                }
            }
            result = client->Stop();
            if (FAILED(result) && streamFailure.empty()) streamFailure = audioError("Stopping microphone", result);
            if (streamFailure.empty()) drain();
            frames.flush();
            // The producer is finished. Drain all accepted frames, including the
            // final partial frame, before allowing stop/destroy to return.
            writer.finish();
            if (const char *error = writer.error(); error && streamFailure.empty()) streamFailure = error;
            SecureZeroMemory(packet.data(), packet.size() * sizeof(int16_t));
            if (!streamFailure.empty()) report(streamFailure);
        } catch (const std::exception &) {
            report("Microphone capture failed while allocating or managing native resources.");
        }
    }
};

JSTICapture *jsti_capture_create(JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback, void *context) {
    if (!callback) return nullptr;
    return new (std::nothrow) JSTICapture(callback, errorCallback, context);
}

int jsti_capture_start(JSTICapture *capture, char *error, size_t capacity) {
    if (!capture) return jsti::fail("No microphone capture instance.", error, capacity);
    if (capture->worker.joinable()) return jsti::fail("The microphone is already started. Stop it before restarting.", error, capacity);
    if (!capture->stop.value) capture->stop.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!capture->stop.value) return jsti::fail(jsti::systemError("Creating microphone stop event"), error, capacity);
    ResetEvent(capture->stop.value);
    { std::lock_guard<std::mutex> lock(capture->failureMutex); capture->failure.clear(); }
    try {
        std::promise<std::string> ready;
        auto initialized = ready.get_future();
        capture->worker = std::thread(&JSTICapture::run, capture, std::move(ready));
        const std::string failure = initialized.get();
        if (!failure.empty()) { capture->worker.join(); return jsti::fail(failure, error, capacity); }
        return 0;
    } catch (const std::exception &) {
        if (capture->worker.joinable()) { SetEvent(capture->stop.value); capture->worker.join(); }
        return jsti::fail("Could not create the microphone capture thread.", error, capacity);
    }
}

int jsti_capture_stop(JSTICapture *capture, char *error, size_t capacity) {
    if (!capture) return jsti::fail("No microphone capture instance.", error, capacity);
    if (activeCaptureCallback == capture) {
        return jsti::fail("Microphone stop must run outside its capture and writer callbacks.", error, capacity);
    }
    if (capture->worker.joinable()) {
        if (capture->worker.get_id() == std::this_thread::get_id()) {
            return jsti::fail("Microphone stop must run outside its audio callback.", error, capacity);
        }
        if (!SetEvent(capture->stop.value)) return jsti::fail(jsti::systemError("Signalling microphone stop"), error, capacity);
        capture->worker.join();
    }
    std::lock_guard<std::mutex> lock(capture->failureMutex);
    return capture->failure.empty() ? 0 : jsti::fail(capture->failure, error, capacity);
}

void jsti_capture_destroy(JSTICapture *capture) {
    if (!capture) return;
    // Refuse a self-join/use-after-free; the caller must destroy on its owner queue.
    if (activeCaptureCallback == capture ||
        (capture->worker.joinable() && capture->worker.get_id() == std::this_thread::get_id())) return;
    jsti_capture_stop(capture, nullptr, 0);
    delete capture;
}

int jsti_native_self_test(char *error, size_t capacity) {
    std::wstring unicode;
    const char *sample = "British English: caf\xc3\xa9 \xf0\x9f\x8e\x99";
    if (!jsti::wide(sample, unicode) || jsti::utf8(unicode) != sample || jsti::wide("\xff", unicode)) {
        return jsti::fail("Unicode round-trip/invalid UTF-8 check failed.", error, capacity);
    }
    struct Check { size_t calls = 0; size_t samples = 0; bool valid = true; } check;
    auto callback = [](const int16_t *data, size_t count, void *context) {
        auto &state = *static_cast<Check *>(context);
        if (count != (state.calls == 2 ? 99 : 1600)) state.valid = false;
        for (size_t i = 0; i < count; ++i) {
            const int16_t expected = state.samples + i < 1700 ? 42 : 0;
            if (data[i] != expected) state.valid = false;
        }
        state.calls++; state.samples += count;
    };
    Frames frames(callback, &check);
    std::array<int16_t, 1700> source;
    source.fill(42);
    frames.append(source.data(), 700);
    frames.append(source.data() + 700, 1000);
    frames.append(nullptr, 1599);
    frames.flush();
    frames.flush();
    if (!check.valid || check.calls != 3 || check.samples != 3299) {
        return jsti::fail("PCM frame boundaries, silent packets or stop flush failed.", error, capacity);
    }
    try {
        auto ring = std::make_unique<PCMFrameRing>();
        std::array<int16_t, PCMFrameRing::frameSamples> data{};
        if (ring->push(data.data(), 0) || ring->push(data.data(), data.size() + 1)) {
            return jsti::fail("The PCM queue accepted an invalid frame size.", error, capacity);
        }
        // Fill before any consumer runs: overflow and wrap checks cannot depend
        // on scheduler timing. Rejected pushes must leave every accepted frame intact.
        for (size_t pass = 0; pass < 3; ++pass) {
            for (size_t index = 0; index < PCMFrameRing::capacity; ++index) {
                data.fill(static_cast<int16_t>(pass * PCMFrameRing::capacity + index + 1));
                const size_t count = index + 1 == PCMFrameRing::capacity ? 99 : data.size();
                if (!ring->push(index % 3 == 0 ? nullptr : data.data(), count)) {
                    return jsti::fail("The PCM queue rejected a frame before capacity.", error, capacity);
                }
            }
            if (ring->push(data.data(), 1)) return jsti::fail("The PCM queue exceeded its fixed capacity.", error, capacity);
            for (size_t index = 0; index < PCMFrameRing::capacity; ++index) {
                const auto *frame = ring->front();
                const size_t count = index + 1 == PCMFrameRing::capacity ? 99 : data.size();
                const int16_t expected = index % 3 == 0 ? 0
                    : static_cast<int16_t>(pass * PCMFrameRing::capacity + index + 1);
                if (!frame || frame->count != count ||
                    !std::all_of(frame->samples.begin(), frame->samples.begin() + count,
                                 [expected](int16_t value) { return value == expected; })) {
                    return jsti::fail("PCM queue FIFO, silence, wrap or partial-frame check failed.", error, capacity);
                }
                ring->pop();
            }
            if (ring->front()) return jsti::fail("The PCM queue did not drain completely.", error, capacity);
        }
        struct WriterCheck { size_t calls = 0; bool valid = true; } written;
        auto writtenCallback = [](const int16_t *data, size_t count, void *context) {
            auto &state = *static_cast<WriterCheck *>(context);
            const size_t expectedCount = state.calls == 2 ? 99 : 1600;
            const int16_t expected = state.calls == 1 ? 0 : 42;
            if (count != expectedCount || !std::all_of(data, data + count,
                [expected](int16_t value) { return value == expected; })) state.valid = false;
            ++state.calls;
        };
        BufferedAudioWriter writer(writtenCallback, &written);
        data.fill(42);
        const bool accepted = writer.append(data.data(), data.size()) && writer.append(nullptr, data.size())
            && writer.append(data.data(), 99);
        writer.finish();
        writer.finish();
        if (!accepted || writer.error() || !written.valid || written.calls != 3 || writer.append(data.data(), 1)) {
            return jsti::fail("Writer drain, repeated close or post-close rejection failed.", error, capacity);
        }
        auto throwingCallback = [](const int16_t *, size_t, void *) { throw 1; };
        BufferedAudioWriter throwingWriter(throwingCallback, nullptr);
        const bool queued = throwingWriter.append(data.data(), 1);
        throwingWriter.finish();
        if (!queued || !throwingWriter.error()) {
            return jsti::fail("The writer did not contain and report a callback exception.", error, capacity);
        }
        struct ReentrancyCheck { JSTICapture *capture; int stopResult = 0; } reentrancy{};
        auto guardedCallback = [](const int16_t *, size_t, void *context) {
            auto &state = *static_cast<ReentrancyCheck *>(context);
            state.stopResult = jsti_capture_stop(state.capture, nullptr, 0);
            // This must be rejected too, leaving the outer owner able to destroy.
            jsti_capture_destroy(state.capture);
        };
        reentrancy.capture = jsti_capture_create(guardedCallback, nullptr, &reentrancy);
        if (!reentrancy.capture) return jsti::fail("Could not allocate callback guard fixture.", error, capacity);
        std::unique_ptr<JSTICapture> guardedCapture(reentrancy.capture);
        BufferedAudioWriter guardedWriter(guardedCallback, &reentrancy, reentrancy.capture);
        const bool guardQueued = guardedWriter.append(data.data(), 1);
        guardedWriter.finish();
        if (!guardQueued || guardedWriter.error() || reentrancy.stopResult != -1) {
            return jsti::fail("Writer callback stop/destroy reentrancy was not rejected.", error, capacity);
        }
    } catch (...) {
        return jsti::fail("PCM queue/writer self-test failed to manage its resources.", error, capacity);
    }
    JSTITextTarget target{};
    char expectedError[256]{};
    if (jsti_target_insert_text(&target, "must not be inserted", expectedError, sizeof(expectedError)) != -1) {
        return jsti::fail("Invalid text target was not rejected.", error, capacity);
    }
    return 0;
}
