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
#include <type_traits>
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

// PCM16 mono rates the Windows audio engine converts to directly in one pass.
// 16 kHz is the legacy default; 24 kHz is the OpenAI Realtime canonical rate.
// Only these two are accepted, so every 100 ms frame fits the fixed storage.
constexpr uint32_t defaultSampleRate = 16000;
constexpr uint32_t maximumSampleRate = 24000;
constexpr size_t maximumFrameSamples = 2400; // 100 ms at the highest supported rate.
constexpr bool supportedSampleRate(uint32_t sampleRate) noexcept {
    return sampleRate == defaultSampleRate || sampleRate == maximumSampleRate;
}
// 100 ms frame target: 1600 or 2400 samples. Clamped so no internal misuse can
// overrun fixed storage or stall framing; the C API rejects other rates earlier.
constexpr size_t frameSamplesFor(uint32_t sampleRate) noexcept {
    const size_t samples = sampleRate / 10;
    return samples < 1 ? 1 : samples > maximumFrameSamples ? maximumFrameSamples : samples;
}
static_assert(frameSamplesFor(defaultSampleRate) == 1600 && frameSamplesFor(maximumSampleRate) == maximumFrameSamples,
              "Frame targets must be 100 ms at each supported capture rate.");

// One producer and one consumer. Slots remain owned by the consumer until its
// borrowed-pointer callback returns. No allocation, mutex or disk I/O in push.
// Slots are sized for the largest supported frame so both rates share one
// fixed layout: 128 slots of 2400 samples, about 600 KiB, 12.8 seconds.
class PCMFrameRing {
public:
    static constexpr size_t slotSamples = maximumFrameSamples;
    static constexpr size_t capacity = 128;
    struct Frame { std::array<int16_t, slotSamples> samples{}; size_t count = 0; };
private:
    std::array<Frame, capacity> slots{};
    alignas(64) std::atomic<size_t> written{0};
    alignas(64) std::atomic<size_t> consumed{0};
public:
    static_assert(std::atomic<size_t>::is_always_lock_free, "Capture indices must be lock-free.");
    bool push(const int16_t *source, size_t count) noexcept {
        if (!count || count > slotSamples) return false;
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

// Regroups driver packets into 100 ms frames at the capture's rate. Storage is
// fixed at the largest frame; only the first `target` samples are ever used.
class Frames {
    std::array<int16_t, maximumFrameSamples> samples{};
    const size_t target;
    size_t used = 0;
    JSTIAudioCallback callback;
    void *context;
public:
    Frames(uint32_t sampleRate, JSTIAudioCallback callback, void *context)
        : target(frameSamplesFor(sampleRate)), callback(callback), context(context) {}
    void append(const int16_t *source, size_t count) {
        while (count) {
            const size_t copied = std::min(count, target - used);
            if (source) std::copy_n(source, copied, samples.data() + used);
            else std::fill_n(samples.data() + used, copied, 0);
            used += copied;
            count -= copied;
            if (source) source += copied;
            if (used == target) flush();
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
    if (result == AUDCLNT_E_DEVICE_INVALIDATED || result == AUDCLNT_E_RESOURCES_INVALIDATED) {
        return "The microphone disconnected or its configuration changed. Recording stopped; choose an available microphone and try again.";
    }
    return jsti::systemError(operation, static_cast<DWORD>(result));
}
}

struct JSTICapture {
    JSTIAudioCallback callback;
    JSTIAudioErrorCallback errorCallback;
    void *context;
    std::wstring deviceIdentifier;
    // Validated at creation and immutable for the capture lifetime.
    const uint32_t sampleRate;
    jsti::Handle stop;
    std::thread worker;
    std::mutex failureMutex;
    std::string failure;

    JSTICapture(JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback, void *context,
                std::wstring deviceIdentifier, uint32_t sampleRate)
        : callback(callback), errorCallback(errorCallback), context(context),
          deviceIdentifier(std::move(deviceIdentifier)), sampleRate(sampleRate) {}

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
            result = deviceIdentifier.empty()
                ? enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications, &device.value)
                : enumerator->GetDevice(deviceIdentifier.c_str(), &device.value);
            if (FAILED(result)) {
                report(deviceIdentifier.empty() ? audioError("Opening the default communications microphone", result)
                    : "The selected microphone is no longer available. Choose an available microphone; no fallback was used.");
                return;
            }
            DWORD deviceState = 0;
            result = device->GetState(&deviceState);
            if (FAILED(result) || !(deviceState & DEVICE_STATE_ACTIVE)) {
                report("The selected microphone is disconnected or disabled. Choose an active microphone; no fallback was used.");
                return;
            }
            jsti::COM<IMMEndpoint> endpoint;
            result = device->QueryInterface(__uuidof(IMMEndpoint), reinterpret_cast<void **>(&endpoint.value));
            EDataFlow flow = eAll;
            if (FAILED(result) || FAILED(endpoint->GetDataFlow(&flow)) || flow != eCapture) {
                report("The selected endpoint is not a microphone. Choose an input device; no fallback was used.");
                return;
            }
            jsti::COM<IAudioClient> client;
            result = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void **>(&client.value));
            if (FAILED(result)) { report(audioError("Activating microphone", result)); return; }
            WAVEFORMATEX format{};
            format.wFormatTag = WAVE_FORMAT_PCM;
            format.nChannels = 1;
            format.nSamplesPerSec = sampleRate;
            format.wBitsPerSample = 16;
            format.nBlockAlign = 2;
            format.nAvgBytesPerSec = sampleRate * format.nBlockAlign;
            // The Windows audio engine converts channels and sample rate straight
            // to the selected rate in one pass; no second 16-to-24 kHz pass, Swift
            // allocation or hand-written low-quality resampler here.
            result = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                    AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                2000000, 0, &format, nullptr);
            if (FAILED(result)) {
                const std::string operation = "Configuring " + std::to_string(sampleRate) + " Hz PCM microphone capture";
                report(audioError(operation.c_str(), result));
                return;
            }
            jsti::Handle available;
            available.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (!available.value) { report(jsti::systemError("Creating microphone event")); return; }
            result = client->SetEventHandle(available.value);
            if (FAILED(result)) { report(audioError("Registering microphone event", result)); return; }
            UINT32 capacity = 0;
            result = client->GetBufferSize(&capacity);
            // An unexpected driver allocation must never cause unbounded growth.
            // The bound is ten seconds at the selected rate: 160000 or 240000 samples.
            const UINT32 maximumCapacity = sampleRate * 10;
            if (FAILED(result) || capacity == 0 || capacity > maximumCapacity) {
                report("The microphone driver returned an invalid or excessive capture buffer."); return;
            }
            std::vector<int16_t> packet(capacity);
            BufferedAudioWriter writer(callback, context, this);
            auto enqueue = [](const int16_t *samples, size_t count, void *value) {
                static_cast<BufferedAudioWriter *>(value)->append(samples, count);
            };
            Frames frames(sampleRate, enqueue, &writer);
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
static_assert(std::is_const_v<decltype(JSTICapture::sampleRate)>, "The capture sample rate must be immutable.");

namespace {
// Shared constructor: validates the callback, rate and identifier without
// touching any device. Hardware is only activated by jsti_capture_start.
JSTICapture *createCapture(const char *deviceID, uint32_t sampleRate, JSTIAudioCallback callback,
                           JSTIAudioErrorCallback errorCallback, void *context, char *error, size_t errorCapacity) {
    try {
        if (!callback) { jsti::fail("No audio callback supplied.", error, errorCapacity); return nullptr; }
        if (!supportedSampleRate(sampleRate)) {
            // The numeric rate is caller configuration, never a secret.
            jsti::fail("Unsupported microphone sample rate " + std::to_string(sampleRate) +
                       " Hz. Only 16000 Hz and 24000 Hz PCM16 mono capture are supported.", error, errorCapacity);
            return nullptr;
        }
        std::wstring identifier;
        if (!jsti::wide(deviceID ? deviceID : "", identifier) || identifier.size() > 32767) {
            jsti::fail("The microphone identifier is not valid UTF-8 or is too long.", error, errorCapacity);
            return nullptr;
        }
        auto capture = new (std::nothrow) JSTICapture(callback, errorCallback, context, std::move(identifier), sampleRate);
        if (!capture) { jsti::fail("Could not allocate microphone capture.", error, errorCapacity); return nullptr; }
        // Success never leaves a stale message from an earlier failure behind.
        if (error && errorCapacity) error[0] = 0;
        return capture;
    } catch (const std::exception &) {
        jsti::fail("Could not retain the selected microphone identifier.", error, errorCapacity);
        return nullptr;
    }
}
}

JSTICapture *jsti_capture_create(JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback, void *context) {
    return createCapture(nullptr, defaultSampleRate, callback, errorCallback, context, nullptr, 0);
}

JSTICapture *jsti_capture_create_with_device(const char *deviceID, JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback errorCallback, void *context,
                                             char *error, size_t errorCapacity) {
    return createCapture(deviceID, defaultSampleRate, callback, errorCallback, context, error, errorCapacity);
}

JSTICapture *jsti_capture_create_with_format(const char *deviceID, uint32_t sampleRate, JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback errorCallback, void *context,
                                             char *error, size_t errorCapacity) {
    return createCapture(deviceID, sampleRate, callback, errorCallback, context, error, errorCapacity);
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

namespace {
struct OwnedCapture {
    JSTICapture *value = nullptr;
    ~OwnedCapture() { jsti_capture_destroy(value); }
};

// Framing at one rate: coalescing into an exact full frame, an exact silent
// frame, a silence/source mix that subdivides a long packet, the partial stop
// flush, a repeated flush and zero-length no-ops. Sample order is verified.
int selfTestFraming(uint32_t sampleRate, char *error, size_t capacity) {
    const size_t frame = frameSamplesFor(sampleRate);
    // A non-zero ramp distinguishes source order from silence at every position.
    std::vector<int16_t> source(frame + 50);
    for (size_t index = 0; index < source.size(); ++index) source[index] = static_cast<int16_t>(index % 30000 + 1);
    struct Check { size_t frame = 0; const int16_t *source = nullptr; size_t calls = 0; size_t samples = 0; bool valid = true; } check;
    check.frame = frame;
    check.source = source.data();
    auto callback = [](const int16_t *data, size_t count, void *context) {
        auto &state = *static_cast<Check *>(context);
        // Frames: exact source frame, exact silent frame, 50 silent samples then
        // source, then the 100-sample stop flush of the remaining source.
        const size_t expectedCount = state.calls == 3 ? 100 : state.frame;
        if (state.calls > 3 || count != expectedCount) { state.valid = false; ++state.calls; return; }
        for (size_t index = 0; index < count && state.valid; ++index) {
            int16_t expected = 0;
            if (state.calls == 0) expected = state.source[index];
            else if (state.calls == 2 && index >= 50) expected = state.source[index - 50];
            else if (state.calls == 3) expected = state.source[state.frame - 50 + index];
            if (data[index] != expected) state.valid = false;
        }
        ++state.calls;
        state.samples += count;
    };
    Frames frames(sampleRate, callback, &check);
    frames.append(source.data(), frame / 2);
    frames.append(source.data() + frame / 2, frame - frame / 2); // Coalesces into exactly one full frame.
    frames.append(nullptr, frame);                                // Exact silent frame.
    frames.append(nullptr, 50);
    frames.append(source.data(), frame + 50);                     // Subdivides; 100 samples stay buffered.
    frames.flush();                                               // Stop flushes the partial frame.
    frames.flush();                                               // A repeated flush publishes nothing.
    frames.append(source.data(), 0);
    frames.append(nullptr, 0);
    frames.flush();
    if (!check.valid || check.calls != 4 || check.samples != 3 * frame + 100) {
        return jsti::fail("PCM frame boundaries, silent packets or stop flush failed at " +
                          std::to_string(sampleRate) + " Hz.", error, capacity);
    }
    return 0;
}

// Fixed-capacity queue: invalid sizes, wrap across three full passes, overflow
// rejection for the smallest and largest frames, FIFO order, silence and a
// trailing partial frame. Slot sizes alternate between 1600 and 2400 samples
// and swap each pass so every slot carries both frame sizes.
int selfTestRing(char *error, size_t capacity) {
    static_assert(PCMFrameRing::slotSamples == 2400 && PCMFrameRing::capacity == 128,
                  "The PCM queue keeps 128 slots of at most 2400 samples for both rates.");
    // Heap allocated like production; the ring is about 600 KiB.
    auto ring = std::make_unique<PCMFrameRing>();
    std::vector<int16_t> data(PCMFrameRing::slotSamples);
    if (ring->push(data.data(), 0) || ring->push(data.data(), data.size() + 1)) {
        return jsti::fail("The PCM queue accepted an invalid frame size.", error, capacity);
    }
    auto countAt = [](size_t pass, size_t index) -> size_t {
        if (index + 1 == PCMFrameRing::capacity) return 99;
        return (index + pass) % 2 ? frameSamplesFor(maximumSampleRate) : frameSamplesFor(defaultSampleRate);
    };
    // Fill before any consumer runs: overflow and wrap checks cannot depend on
    // scheduler timing. Rejected pushes must leave every accepted frame intact.
    for (size_t pass = 0; pass < 3; ++pass) {
        for (size_t index = 0; index < PCMFrameRing::capacity; ++index) {
            std::fill(data.begin(), data.end(), static_cast<int16_t>(pass * PCMFrameRing::capacity + index + 1));
            if (!ring->push(index % 3 == 0 ? nullptr : data.data(), countAt(pass, index))) {
                return jsti::fail("The PCM queue rejected a frame before capacity.", error, capacity);
            }
        }
        if (ring->push(data.data(), 1) || ring->push(data.data(), data.size())) {
            return jsti::fail("The PCM queue exceeded its fixed capacity.", error, capacity);
        }
        for (size_t index = 0; index < PCMFrameRing::capacity; ++index) {
            const auto *frame = ring->front();
            const size_t count = countAt(pass, index);
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
    return 0;
}

// Writer drain at one frame size: a full frame, a full silent frame and a
// partial frame all reach the callback intact before finish returns; a second
// finish is harmless and later appends are rejected.
int selfTestWriter(uint32_t sampleRate, char *error, size_t capacity) {
    struct Check { size_t frame = 0; size_t calls = 0; bool valid = true; } written;
    written.frame = frameSamplesFor(sampleRate);
    auto callback = [](const int16_t *data, size_t count, void *context) {
        auto &state = *static_cast<Check *>(context);
        const size_t expectedCount = state.calls == 2 ? 99 : state.frame;
        const int16_t expected = state.calls == 1 ? 0 : 42;
        if (count != expectedCount || !std::all_of(data, data + count,
            [expected](int16_t value) { return value == expected; })) state.valid = false;
        ++state.calls;
    };
    std::vector<int16_t> data(written.frame, int16_t{42});
    BufferedAudioWriter writer(callback, &written);
    const bool accepted = writer.append(data.data(), data.size()) && writer.append(nullptr, data.size())
        && writer.append(data.data(), 99);
    writer.finish();
    writer.finish();
    if (!accepted || writer.error() || !written.valid || written.calls != 3 || writer.append(data.data(), 1)) {
        return jsti::fail("Writer drain, repeated close or post-close rejection failed at " +
                          std::to_string(sampleRate) + " Hz.", error, capacity);
    }
    return 0;
}

// Creation-time validation only: no capture is started, so no microphone is
// activated and neither callback may run.
int selfTestCreation(char *error, size_t capacity) {
    struct Callbacks { size_t audio = 0; size_t errors = 0; } callbacks;
    const auto audio = [](const int16_t *, size_t, void *context) { ++static_cast<Callbacks *>(context)->audio; };
    const auto failed = [](const char *, void *context) { ++static_cast<Callbacks *>(context)->errors; };
    char detail[256]{};
    const auto stale = [&detail]() { std::memcpy(detail, "stale", 6); };
    // Only 16 kHz and 24 kHz PCM16 mono are accepted; nothing near them is.
    const uint32_t rejectedRates[] = {0, 8000, 16001, 22050, 44100, 48000, (std::numeric_limits<uint32_t>::max)()};
    for (const uint32_t rate : rejectedRates) {
        detail[0] = 0;
        OwnedCapture rejected{jsti_capture_create_with_format("", rate, audio, failed, &callbacks, detail, sizeof(detail))};
        if (rejected.value || !detail[0]) {
            return jsti::fail("An unsupported capture sample rate was accepted or left unreported.", error, capacity);
        }
    }
    detail[0] = 0;
    OwnedCapture noCallback{jsti_capture_create_with_format("", maximumSampleRate, nullptr, failed, &callbacks,
                                                            detail, sizeof(detail))};
    if (noCallback.value || !detail[0]) return jsti::fail("A capture without an audio callback was accepted.", error, capacity);
    detail[0] = 0;
    OwnedCapture invalidDevice{jsti_capture_create_with_format("\xff", maximumSampleRate, audio, failed, &callbacks,
                                                               detail, sizeof(detail))};
    if (invalidDevice.value || !detail[0]) {
        return jsti::fail("An invalid UTF-8 microphone identifier was accepted at 24 kHz.", error, capacity);
    }
    // Success clears a stale message, records the immutable rate and treats a
    // null or empty identifier as the default communications microphone.
    stale();
    OwnedCapture realtime{jsti_capture_create_with_format(nullptr, maximumSampleRate, audio, failed, &callbacks,
                                                          detail, sizeof(detail))};
    if (!realtime.value || detail[0] || realtime.value->sampleRate != maximumSampleRate ||
        !realtime.value->deviceIdentifier.empty()) {
        return jsti::fail("24 kHz capture creation, default device or stale error clearing failed.", error, capacity);
    }
    stale();
    OwnedCapture explicitDevice{jsti_capture_create_with_format("jsti-self-test-explicit-microphone", maximumSampleRate,
                                                                audio, failed, &callbacks, detail, sizeof(detail))};
    if (!explicitDevice.value || detail[0] || explicitDevice.value->sampleRate != maximumSampleRate ||
        explicitDevice.value->deviceIdentifier != L"jsti-self-test-explicit-microphone") {
        return jsti::fail("An explicit microphone identifier was not retained at 24 kHz.", error, capacity);
    }
    // Every legacy constructor agrees with the explicit 16 kHz default.
    stale();
    OwnedCapture formatted{jsti_capture_create_with_format("", defaultSampleRate, audio, failed, &callbacks,
                                                           detail, sizeof(detail))};
    OwnedCapture legacy{jsti_capture_create(audio, failed, &callbacks)};
    OwnedCapture legacyDevice{jsti_capture_create_with_device(nullptr, audio, failed, &callbacks, detail, sizeof(detail))};
    if (!formatted.value || !legacy.value || !legacyDevice.value || detail[0] ||
        formatted.value->sampleRate != defaultSampleRate || legacy.value->sampleRate != defaultSampleRate ||
        legacyDevice.value->sampleRate != defaultSampleRate || !formatted.value->deviceIdentifier.empty() ||
        !legacy.value->deviceIdentifier.empty() || !legacyDevice.value->deviceIdentifier.empty()) {
        return jsti::fail("Capture constructors do not agree on the 16 kHz default.", error, capacity);
    }
    // Never-started captures stop cleanly at either rate without any callback.
    if (jsti_capture_stop(realtime.value, detail, sizeof(detail)) != 0 ||
        jsti_capture_stop(legacy.value, detail, sizeof(detail)) != 0 || callbacks.audio || callbacks.errors) {
        return jsti::fail("Unstarted captures did not stop cleanly without callbacks.", error, capacity);
    }
    return 0;
}
}

int jsti_native_self_test(char *error, size_t capacity) {
    std::wstring unicode;
    const char *sample = "British English: caf\xc3\xa9 \xf0\x9f\x8e\x99";
    if (!jsti::wide(sample, unicode) || jsti::utf8(unicode) != sample || jsti::wide("\xff", unicode)) {
        return jsti::fail("Unicode round-trip/invalid UTF-8 check failed.", error, capacity);
    }
    try {
        for (const uint32_t sampleRate : {defaultSampleRate, maximumSampleRate}) {
            if (selfTestFraming(sampleRate, error, capacity) || selfTestWriter(sampleRate, error, capacity)) return -1;
        }
        if (selfTestRing(error, capacity) || selfTestCreation(error, capacity)) return -1;
        std::vector<int16_t> data(1);
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
    return jsti_audio_devices_self_test(error, capacity);
}
