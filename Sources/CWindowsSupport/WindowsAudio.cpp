#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <avrt.h>
#include <array>
#include <cmath>
#include <atomic>
#include <future>
#include <mutex>
#include <memory>
#include <stdexcept>
#include <new>
#include <thread>
#include <type_traits>
#include <vector>
#include <condition_variable>
#include <system_error>

namespace {
std::atomic<float> latestCaptureLevel{0.0f};
}

void jsti::publishCaptureLevel(const int16_t *samples, size_t count) noexcept {
    if (!samples || !count) return;
    double sum = 0;
    for (size_t index = 0; index < count; ++index) sum += static_cast<double>(samples[index]) * samples[index];
    const double rms = std::sqrt(sum / static_cast<double>(count)) / 32768.0;
    const double decibels = rms > 0 ? 20.0 * std::log10(rms) : -100.0;
    latestCaptureLevel.store(static_cast<float>(std::clamp((decibels + 50.0) / 50.0, 0.0, 1.0)),
                             std::memory_order_relaxed);
}

float jsti::captureLevel() noexcept { return latestCaptureLevel.load(std::memory_order_relaxed); }

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

// PCM16 mono rates the Windows engine converts to directly in one pass.
constexpr uint32_t defaultSampleRate = 16000;
constexpr uint32_t maximumSampleRate = 24000;
constexpr uint32_t defaultFrameMilliseconds = 100;
constexpr uint32_t minimumFrameMilliseconds = 20;
constexpr size_t maximumFrameSamples = 2400;
constexpr size_t bufferedMilliseconds = 12800;
constexpr bool supportedSampleRate(uint32_t sampleRate) noexcept {
    return sampleRate == defaultSampleRate || sampleRate == maximumSampleRate;
}
constexpr bool supportedFrameMilliseconds(uint32_t milliseconds) noexcept {
    return milliseconds == minimumFrameMilliseconds || milliseconds == defaultFrameMilliseconds;
}
constexpr size_t frameSamplesFor(uint32_t sampleRate,
                                uint32_t milliseconds = defaultFrameMilliseconds) noexcept {
    return static_cast<size_t>(sampleRate) * milliseconds / 1000;
}
size_t validatedFrameSamples(uint32_t sampleRate, uint32_t milliseconds) {
    if (!supportedSampleRate(sampleRate) || !supportedFrameMilliseconds(milliseconds)) {
        throw std::invalid_argument("Unsupported microphone frame format.");
    }
    return frameSamplesFor(sampleRate, milliseconds);
}
static_assert(frameSamplesFor(maximumSampleRate) == maximumFrameSamples);

// One producer and one consumer. A borrowed slot stays owned by the consumer
// until its callback returns. Push never allocates, locks or performs disk I/O.
// The same 600 KiB PCM store supplies 128 x 100 ms or 640 x 20 ms slots, retaining
// 12.8 seconds at either rate/duration. Slot metadata is also allocated once.
class PCMFrameRing {
public:
    static constexpr size_t maximumSlots = bufferedMilliseconds / minimumFrameMilliseconds;
    static constexpr size_t storageSamples = maximumFrameSamples * bufferedMilliseconds / defaultFrameMilliseconds;
    struct Frame { int16_t *samples = nullptr; size_t count = 0; };
    const size_t slotSamples;
    const size_t slotCount;
private:
    std::array<int16_t, storageSamples> samples{};
    std::array<Frame, maximumSlots> slots{};
    alignas(64) std::atomic<size_t> written{0};
    alignas(64) std::atomic<size_t> consumed{0};
public:
    static_assert(std::atomic<size_t>::is_always_lock_free, "Capture indices must be lock-free.");
    explicit PCMFrameRing(uint32_t sampleRate = maximumSampleRate,
                          uint32_t milliseconds = defaultFrameMilliseconds)
        : slotSamples(validatedFrameSamples(sampleRate, milliseconds)),
          slotCount(bufferedMilliseconds / milliseconds) {
        for (size_t index = 0; index < slotCount; ++index) {
            slots[index].samples = samples.data() + index * slotSamples;
        }
    }
    bool push(const int16_t *source, size_t count) noexcept {
        if (!count || count > slotSamples) return false;
        const size_t write = written.load(std::memory_order_relaxed);
        if (write - consumed.load(std::memory_order_acquire) >= slotCount) return false;
        Frame &slot = slots[write % slotCount];
        if (source) std::copy_n(source, count, slot.samples);
        else std::fill_n(slot.samples, count, 0);
        slot.count = count;
        written.store(write + 1, std::memory_order_release);
        return true;
    }
    const Frame *front() const noexcept {
        const size_t read = consumed.load(std::memory_order_relaxed);
        if (read == written.load(std::memory_order_acquire)) return nullptr;
        return &slots[read % slotCount];
    }
    void pop() noexcept {
        consumed.store(consumed.load(std::memory_order_relaxed) + 1, std::memory_order_release);
    }
};

class BufferedAudioWriter {
    enum class Failure { none, overflow, callback, wake, wait };
    // Heap allocation avoids exhausting the Windows capture thread's stack.
    std::unique_ptr<PCMFrameRing> ring;
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
                    callback(frame->samples, frame->count, context);
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
    BufferedAudioWriter(JSTIAudioCallback callback, void *context, const JSTICapture *owner = nullptr,
                        uint32_t sampleRate = maximumSampleRate,
                        uint32_t milliseconds = defaultFrameMilliseconds)
        : ring(std::make_unique<PCMFrameRing>(sampleRate, milliseconds)),
          callback(callback), context(context), owner(owner) {
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
    bool retireEvent() {
        if (worker.joinable()) return false;
        if (available.value && !CloseHandle(available.value)) return false;
        available.value = nullptr;
        return true;
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

// Regroups driver packets into the chosen duration at the capture's rate. Storage is
// fixed at the largest frame; only the first `target` samples are ever used.
class Frames {
    std::array<int16_t, maximumFrameSamples> samples{};
    const size_t target;
    size_t used = 0;
    JSTIAudioCallback callback;
    void *context;
public:
    Frames(uint32_t sampleRate, JSTIAudioCallback callback, void *context,
           uint32_t milliseconds = defaultFrameMilliseconds)
        : target(validatedFrameSamples(sampleRate, milliseconds)), callback(callback), context(context) {}
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
        if (used) {
            jsti::publishCaptureLevel(samples.data(), used);
            callback(samples.data(), used, context);
            used = 0;
        }
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

struct OwnedCaptureControl {
    std::mutex mutex;
    std::condition_variable changed, retry;
    bool quiesced = false;
    bool retireRequested = false;
    bool retirementReady = false;
    bool stopHandleAmbiguous = false;
    uint64_t retryGeneration = 0;
    std::string operationFailure;
    std::atomic<uint32_t> faults{0};

    bool consumeFault(uint32_t bit) noexcept {
        return (faults.fetch_and(~bit, std::memory_order_relaxed) & bit) != 0;
    }
    void failedUntilRetry(const char *message) {
        std::unique_lock<std::mutex> lock(mutex);
        const auto generation = retryGeneration;
        operationFailure = message;
        changed.notify_all();
        retry.wait(lock, [&] { return retryGeneration != generation; });
    }
    void finishWriter(BufferedAudioWriter &writer) {
        while (true) {
            try {
                if (consumeFault(4)) throw std::system_error(std::make_error_code(std::errc::io_error));
                writer.finish();
                return;
            } catch (const std::system_error &) {
                // Keep the producer stack, writer and its joinable thread alive.
                failedUntilRetry("Joining the owned audio writer failed; ownership is retained.");
            }
        }
    }
    void park() {
        std::unique_lock<std::mutex> lock(mutex);
        quiesced = true;
        changed.notify_all();
        retry.wait(lock, [&] { return retireRequested; });
    }
    void retireEvents(BufferedAudioWriter *writer, jsti::Handle *available = nullptr) {
        bool ambiguous = false;
        while (true) {
            if (!ambiguous) {
                if (writer && !writer->retireEvent()) ambiguous = true;
                if (!ambiguous && available && available->value) {
                    if (!CloseHandle(available->value)) ambiguous = true;
                    else available->value = nullptr;
                }
            }
            if (!ambiguous) break;
            // A failed real CloseHandle gives no authority to reuse/re-close a
            // numeric handle. Keep the complete producer stack, do not free it.
            failedUntilRetry("Owned event retirement is ambiguous; native ownership remains retained.");
        }
        std::lock_guard<std::mutex> lock(mutex);
        retirementReady = true;
        changed.notify_all();
    }
};

template<class Action> struct ProducerScope {
    Action action;
    ~ProducerScope() { action(); }
};
}

struct JSTICapture {
    JSTIAudioCallback callback;
    JSTIAudioErrorCallback errorCallback;
    void *context;
    std::wstring deviceIdentifier;
    // Validated at creation and immutable for the capture lifetime.
    const uint32_t sampleRate;
    const uint32_t frameMilliseconds;
    jsti::Handle stop;
    std::thread worker;
    std::mutex failureMutex;
    std::string failure;
    OwnedCaptureControl *owned = nullptr;

    JSTICapture(JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback, void *context,
                std::wstring deviceIdentifier, uint32_t sampleRate, uint32_t frameMilliseconds)
        : callback(callback), errorCallback(errorCallback), context(context),
          deviceIdentifier(std::move(deviceIdentifier)), sampleRate(sampleRate), frameMilliseconds(frameMilliseconds) {}

    void run(std::promise<std::string> ready) {
        bool announced = false;
        auto report = [&](const std::string &message) {
            if (owned) {
                bool first = false;
                {
                    std::lock_guard<std::mutex> lock(failureMutex);
                    if (failure.empty()) { failure = message.substr(0, 1023); first = true; }
                }
                if (first && errorCallback) {
                    CaptureCallbackScope scope(this);
                    try { errorCallback(message.c_str(), context); } catch (...) { /* C callback boundary. */ }
                }
                if (!announced) { ready.set_value(message); announced = true; }
                return;
            }
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
            jsti::COM<IMMDeviceEnumerator> enumerator;
            jsti::COM<IMMDevice> device;
            jsti::COM<IMMEndpoint> endpoint;
            jsti::COM<IAudioClient> client;
            jsti::COM<IAudioCaptureClient> reader;
            jsti::Handle available;
            std::unique_ptr<BufferedAudioWriter> writer;
            bool clientStarted = false;
            auto finish = [&] {
                if (!owned) return;
                if (!announced || std::uncaught_exceptions()) {
                    report("Owned microphone initialization or capture failed.");
                }
                while (clientStarted) {
                    const HRESULT stopped = client->Stop();
                    if (SUCCEEDED(stopped)) { clientStarted = false; break; }
                    report(audioError("Stopping owned microphone", stopped));
                    owned->failedUntilRetry("The owned microphone has not stopped; ownership retained.");
                }
                if (writer) {
                    owned->finishWriter(*writer);
                    if (const char *error = writer->error()) report(error);
                }
                owned->park();
                owned->retireEvents(writer.get(), &available);
            };
            // Park BEFORE destruction of writer/COM/event resources on this same
            // producer thread. Even an early failed open retains its owner.
            ProducerScope<decltype(finish)> terminal{finish};
            if (FAILED(apartment.result)) { report(audioError("Initializing microphone COM", apartment.result)); return; }
            HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator.value));
            if (FAILED(result)) { report(audioError("Finding microphones", result)); return; }
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
            result = device->QueryInterface(__uuidof(IMMEndpoint), reinterpret_cast<void **>(&endpoint.value));
            EDataFlow flow = eAll;
            if (FAILED(result) || FAILED(endpoint->GetDataFlow(&flow)) || flow != eCapture) {
                report("The selected endpoint is not a microphone. Choose an input device; no fallback was used.");
                return;
            }
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
            writer = std::make_unique<BufferedAudioWriter>(callback, context, this, sampleRate, frameMilliseconds);
            auto enqueue = [](const int16_t *samples, size_t count, void *value) {
                static_cast<BufferedAudioWriter *>(value)->append(samples, count);
            };
            Frames frames(sampleRate, enqueue, writer.get(), frameMilliseconds);
            result = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void **>(&reader.value));
            if (FAILED(result)) { report(audioError("Opening microphone capture stream", result)); return; }
            Scheduling scheduling;
            // MMCSS is an optimisation. Capture still works at normal priority
            // when the scheduler service is unavailable or disabled by policy.
            result = client->Start();
            if (FAILED(result)) { report(audioError("Starting microphone", result)); return; }
            clientStarted = true;
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
                    // Publish after releasing the driver buffer; Swift runs only on the writer thread.
                    frames.append(silence ? nullptr : packet.data(), count);
                    if (const char *error = writer->error()) { streamFailure = error; return false; }
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
            if (SUCCEEDED(result)) clientStarted = false;
            if (FAILED(result) && streamFailure.empty()) streamFailure = audioError("Stopping microphone", result);
            if (streamFailure.empty()) drain();
            frames.flush();
            // The producer is finished. Drain all accepted frames, including the
            // final partial frame, before allowing stop/destroy to return.
            if (owned) owned->finishWriter(*writer);
            else writer->finish();
            if (const char *error = writer->error(); error && streamFailure.empty()) streamFailure = error;
            SecureZeroMemory(packet.data(), packet.size() * sizeof(int16_t));
            if (!streamFailure.empty()) report(streamFailure);
        } catch (const std::exception &) {
            report("Microphone capture failed while allocating or managing native resources.");
        }
    }
};
static_assert(std::is_const_v<decltype(JSTICapture::sampleRate)> &&
              std::is_const_v<decltype(JSTICapture::frameMilliseconds)>, "The capture format must be immutable.");

namespace {
// Shared constructor: validates the callback, rate and identifier without
// touching any device. Hardware is only activated by jsti_capture_start.
JSTICapture *createCapture(const char *deviceID, uint32_t sampleRate, uint32_t frameMilliseconds,
                           JSTIAudioCallback callback,
                           JSTIAudioErrorCallback errorCallback, void *context, char *error, size_t errorCapacity) {
    try {
        if (!callback) { jsti::fail("No audio callback supplied.", error, errorCapacity); return nullptr; }
        if (!supportedSampleRate(sampleRate)) {
            // The numeric rate is caller configuration, never a secret.
            jsti::fail("Unsupported microphone sample rate " + std::to_string(sampleRate) +
                       " Hz. Only 16000 Hz and 24000 Hz PCM16 mono capture are supported.", error, errorCapacity);
            return nullptr;
        }
        if (!supportedFrameMilliseconds(frameMilliseconds)) {
            jsti::fail("Unsupported microphone frame duration " + std::to_string(frameMilliseconds) +
                       " ms. Only 20 ms and 100 ms capture frames are supported.", error, errorCapacity);
            return nullptr;
        }
        std::wstring identifier;
        if (!jsti::wide(deviceID ? deviceID : "", identifier) || identifier.size() > 32767) {
            jsti::fail("The microphone identifier is not valid UTF-8 or is too long.", error, errorCapacity);
            return nullptr;
        }
        auto capture = new (std::nothrow) JSTICapture(
            callback, errorCallback, context, std::move(identifier), sampleRate, frameMilliseconds);
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
    return createCapture(nullptr, defaultSampleRate, defaultFrameMilliseconds, callback, errorCallback, context, nullptr, 0);
}

JSTICapture *jsti_capture_create_with_device(const char *deviceID, JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback errorCallback, void *context,
                                             char *error, size_t errorCapacity) {
    return createCapture(deviceID, defaultSampleRate, defaultFrameMilliseconds, callback, errorCallback, context, error, errorCapacity);
}

JSTICapture *jsti_capture_create_with_format(const char *deviceID, uint32_t sampleRate, JSTIAudioCallback callback,
                                             JSTIAudioErrorCallback errorCallback, void *context,
                                             char *error, size_t errorCapacity) {
    return createCapture(deviceID, sampleRate, defaultFrameMilliseconds, callback, errorCallback, context, error, errorCapacity);
}

JSTICapture *jsti_capture_create_with_options(const char *deviceID, uint32_t sampleRate, uint32_t frameMilliseconds,
                                              JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback,
                                              void *context, char *error, size_t errorCapacity) {
    return createCapture(deviceID, sampleRate, frameMilliseconds, callback, errorCallback, context, error, errorCapacity);
}

int jsti_capture_start(JSTICapture *capture, char *error, size_t capacity) {
    if (!capture) return jsti::fail("No microphone capture instance.", error, capacity);
    if (capture->owned) return jsti::fail("Owned capture requires its owned control API.", error, capacity);
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
    if (capture->owned) return jsti::fail("Owned capture requires its owned control API.", error, capacity);
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
    if (capture->owned) return;
    // Refuse a self-join/use-after-free; the caller must destroy on its owner queue.
    if (activeCaptureCallback == capture ||
        (capture->worker.joinable() && capture->worker.get_id() == std::this_thread::get_id())) return;
    jsti_capture_stop(capture, nullptr, 0);
    delete capture;
}

struct JSTIOwnedCapture {
    const std::string id;
    OwnedCaptureControl control;
    JSTICapture *capture = nullptr;
    const JSTIAudioCallback audio;
    const JSTIAudioErrorCallback failed;
    void *const context;
    std::atomic<uint64_t> delivered{0};

    JSTIOwnedCapture(std::string id, JSTIAudioCallback audio, JSTIAudioErrorCallback failed, void *context)
        : id(std::move(id)), audio(audio), failed(failed), context(context) {}
};

namespace {
int ownedControlFailure(const char *message, char *error, size_t capacity) noexcept {
    if (error && capacity) {
        const size_t count = std::min(std::strlen(message), capacity - 1);
        std::memcpy(error, message, count);
        error[count] = 0;
    }
    return -1;
}

bool validOwnedReceipt(JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    if (!receipt || receipt->size != sizeof(*receipt) || receipt->version != JSTI_OWNED_CAPTURE_VERSION) {
        jsti::fail("Unsupported owned capture receipt size/version.", error, capacity);
        return false;
    }
    return true;
}

void ownedReceipt(JSTIOwnedCapture *owner, JSTIOwnedCaptureReceipt *receipt, bool retired = false) {
    receipt->flags = retired ? JSTI_OWNED_RESOURCES_RETIRED : JSTI_OWNED_OWNERSHIP_RETAINED;
    receipt->delivered_samples = owner->delivered.load(std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(owner->control.mutex);
        if (owner->control.quiesced) receipt->flags |= JSTI_OWNED_PRODUCER_QUIESCED | JSTI_OWNED_CALLBACKS_DRAINED;
    }
    std::lock_guard<std::mutex> lock(owner->capture->failureMutex);
    std::memset(receipt->first_audio_error, 0, sizeof(receipt->first_audio_error));
    if (!owner->capture->failure.empty()) {
        receipt->flags |= JSTI_OWNED_AUDIO_FAILED;
        std::memcpy(receipt->first_audio_error, owner->capture->failure.data(),
                    std::min(owner->capture->failure.size(), sizeof(receipt->first_audio_error) - 1));
    }
}

bool validOwnedRun(JSTIOwnedCapture *owner, const char *id, char *error, size_t capacity) {
    if (!owner || !id || owner->id != id) {
        jsti::fail("Stale owned capture run identity.", error, capacity);
        return false;
    }
    if (activeCaptureCallback == owner->capture ||
        (owner->capture->worker.joinable() && owner->capture->worker.get_id() == std::this_thread::get_id())) {
        jsti::fail("Owned capture control cannot run inside its native callback/producer.", error, capacity);
        return false;
    }
    return true;
}

void ownedAudio(const int16_t *samples, size_t count, void *context) {
    auto *owner = static_cast<JSTIOwnedCapture *>(context);
    owner->audio(samples, count, owner->context);
    owner->delivered.fetch_add(count, std::memory_order_relaxed);
}

void ownedFailure(const char *message, void *context) {
    auto *owner = static_cast<JSTIOwnedCapture *>(context);
    if (owner->failed) owner->failed(message, owner->context);
}

// The fixture uses the real framing/ring/writer/control/retirement paths but
// never opens an endpoint. All storage stays owned until the real threads join.
void ownedFixtureRun(JSTIOwnedCapture *owner, std::promise<std::string> ready) {
    auto &capture = *owner->capture;
    auto report = [&](const std::string &message) {
        bool first = false;
        {
            std::lock_guard<std::mutex> lock(capture.failureMutex);
            if (capture.failure.empty()) { capture.failure = message.substr(0, 1023); first = true; }
        }
        if (first) {
            CaptureCallbackScope scope(&capture);
            try { ownedFailure(message.c_str(), owner); } catch (...) { /* C callback boundary. */ }
        }
    };
    std::unique_ptr<BufferedAudioWriter> writer;
    bool announced = false;
    auto finish = [&] {
        if (!announced) { report("Owned fixture failed before readiness."); ready.set_value("Fixture open failed."); }
        if (writer) {
            owner->control.finishWriter(*writer);
            if (const char *message = writer->error()) report(message);
        }
        if (owner->control.consumeFault(8)) report("Synthetic late native audio failure.");
        owner->control.park();
        owner->control.retireEvents(writer.get());
    };
    ProducerScope<decltype(finish)> terminal{finish};
    try {
        if (owner->control.consumeFault(16)) {
            report("Synthetic partial native open failure.");
            ready.set_value("Synthetic partial native open failure.");
            announced = true;
            return;
        }
        writer = std::make_unique<BufferedAudioWriter>(ownedAudio, owner, &capture,
                                                       capture.sampleRate, capture.frameMilliseconds);
        const auto enqueue = [](const int16_t *samples, size_t count, void *value) {
            static_cast<BufferedAudioWriter *>(value)->append(samples, count);
        };
        Frames frames(capture.sampleRate, enqueue, writer.get(), capture.frameMilliseconds);
        ready.set_value({});
        announced = true;
        if (WaitForSingleObject(capture.stop.value, INFINITE) != WAIT_OBJECT_0) {
            report("Waiting for the synthetic owned producer failed.");
        } else {
            std::array<int16_t, 73> tail{};
            for (size_t i = 0; i < tail.size(); ++i) tail[i] = static_cast<int16_t>(i + 1);
            frames.append(tail.data(), tail.size());
            frames.flush();
            frames.flush();
        }
    } catch (...) {
        report("Synthetic owned producer failed.");
        if (!announced) { ready.set_value("Synthetic owned open failed."); announced = true; }
    }
}

int openOwned(JSTIOwnedCapture **slot, const char *id, const char *device, uint32_t rate, uint32_t frame,
              JSTIAudioCallback audio, JSTIAudioErrorCallback failure, void *context, bool fixture, uint32_t faults,
              JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    if (!validOwnedReceipt(receipt, error, capacity)) return -1;
    if (!slot || *slot || !id || !*id || std::strlen(id) > 64 || !audio ||
        !supportedSampleRate(rate) || !supportedFrameMilliseconds(frame) || (faults & ~31u)) {
        return jsti::fail("Invalid owned capture configuration or occupied slot.", error, capacity);
    }
    try {
        auto owner = std::make_unique<JSTIOwnedCapture>(id, audio, failure, context);
        owner->capture = createCapture(device, rate, frame, ownedAudio, ownedFailure, owner.get(), error, capacity);
        if (!owner->capture) return -1;
        owner->capture->owned = &owner->control;
        owner->control.faults.store(faults, std::memory_order_relaxed);
        *slot = owner.release(); // Publish before any blocking native operation.
        auto &capture = *(*slot)->capture;
        capture.stop.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!capture.stop.value) {
            ownedReceipt(*slot, receipt);
            return jsti::fail(jsti::systemError("Creating owned stop event"), error, capacity);
        }
        std::promise<std::string> ready;
        auto initialized = ready.get_future();
        if (fixture) capture.worker = std::thread(ownedFixtureRun, *slot, std::move(ready));
        else capture.worker = std::thread(&JSTICapture::run, &capture, std::move(ready));
        const auto message = initialized.get();
        ownedReceipt(*slot, receipt);
        if (!message.empty()) return jsti::fail(message, error, capacity);
        return 0;
    } catch (...) {
        if (slot && *slot) ownedReceipt(*slot, receipt);
        return jsti::fail("Owned capture open failed; retain any partial owner for retirement.", error, capacity);
    }
}

int quiesceOwned(JSTIOwnedCapture *owner, JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    auto &control = owner->control;
    {
        std::unique_lock<std::mutex> lock(control.mutex);
        if (!control.quiesced) {
            if (!owner->capture->worker.joinable()) {
                control.quiesced = true; // Thread creation never succeeded; there are no callbacks to join.
            } else {
                if (control.consumeFault(1) || !SetEvent(owner->capture->stop.value)) {
                    lock.unlock();
                    ownedReceipt(owner, receipt);
                    return jsti::fail("Signalling owned producer stop failed; ownership retained.", error, capacity);
                }
                control.operationFailure.clear();
                ++control.retryGeneration;
                control.retry.notify_all();
                control.changed.wait(lock, [&] { return control.quiesced || !control.operationFailure.empty(); });
                if (!control.operationFailure.empty()) {
                    const auto message = control.operationFailure;
                    lock.unlock();
                    ownedReceipt(owner, receipt);
                    return jsti::fail(message, error, capacity);
                }
            }
        }
    }
    ownedReceipt(owner, receipt);
    if (receipt->flags & JSTI_OWNED_AUDIO_FAILED) return jsti::fail(receipt->first_audio_error, error, capacity);
    return 0;
}
}

int jsti_owned_capture_open(JSTIOwnedCapture **owner, const char *id, const char *device,
                            uint32_t rate, uint32_t frame, JSTIAudioCallback audio,
                            JSTIAudioErrorCallback failure, void *context,
                            JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    try {
        return openOwned(owner, id, device, rate, frame, audio, failure, context, false, 0, receipt, error, capacity);
    } catch (...) {
        return ownedControlFailure("Owned open failed; preserve any published owner.", error, capacity);
    }
}

int jsti_owned_capture_open_fixture(JSTIOwnedCapture **owner, const char *id, uint32_t faults,
                                    uint32_t rate, uint32_t frame, JSTIAudioCallback audio,
                                    JSTIAudioErrorCallback failure, void *context,
                                    JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    try {
        return openOwned(owner, id, "", rate, frame, audio, failure, context, true, faults, receipt, error, capacity);
    } catch (...) {
        return ownedControlFailure("Owned fixture open failed; preserve any published owner.", error, capacity);
    }
}

int jsti_owned_capture_quiesce(JSTIOwnedCapture *owner, const char *id,
                               JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    try {
        if (!validOwnedReceipt(receipt, error, capacity) || !validOwnedRun(owner, id, error, capacity)) return -1;
        return quiesceOwned(owner, receipt, error, capacity);
    } catch (...) {
        return ownedControlFailure("Owned quiescence failed without releasing ownership.", error, capacity);
    }
}

int jsti_owned_capture_retire(JSTIOwnedCapture **slot, const char *id,
                              JSTIOwnedCaptureReceipt *receipt, char *error, size_t capacity) {
    try {
        if (!validOwnedReceipt(receipt, error, capacity)) return -1;
        if (!slot) return ownedControlFailure("No owned capture slot supplied for retirement.", error, capacity);
        if (!validOwnedRun(*slot, id, error, capacity)) return -1;
        auto *owner = *slot;
        quiesceOwned(owner, receipt, error, capacity);
        {
            std::lock_guard<std::mutex> lock(owner->control.mutex);
            if (!owner->control.quiesced) return -1;
            owner->control.operationFailure.clear();
            owner->control.retireRequested = true;
            if (!owner->capture->worker.joinable()) owner->control.retirementReady = true;
            ++owner->control.retryGeneration;
            owner->control.retry.notify_all();
        }
        {
            std::unique_lock<std::mutex> lock(owner->control.mutex);
            owner->control.changed.wait(lock, [&] {
                return owner->control.retirementReady || !owner->control.operationFailure.empty();
            });
            if (!owner->control.operationFailure.empty()) {
                return jsti::fail(owner->control.operationFailure, error, capacity);
            }
        }
        if (owner->control.consumeFault(2)) {
            return jsti::fail("Joining owned producer failed; ownership retained.", error, capacity);
        }
        // COM destruction runs on the producer after its retirement signal.
        if (owner->capture->worker.joinable()) owner->capture->worker.join();
        if (owner->capture->stop.value) {
            if (owner->control.stopHandleAmbiguous || !CloseHandle(owner->capture->stop.value)) {
                owner->control.stopHandleAmbiguous = true;
                return jsti::fail("Owned stop-event retirement is ambiguous; owner retained.", error, capacity);
            }
            owner->capture->stop.value = nullptr;
        }
        ownedReceipt(owner, receipt, true);
        delete owner->capture;
        delete owner;
        *slot = nullptr;
        return 0;
    } catch (...) {
        return ownedControlFailure("Owned retirement failed; native owner and callbacks must be retained.", error, capacity);
    }
}

int jsti_owned_capture_self_test(char *error, size_t capacity) {
    struct Check {
        std::array<int16_t, 73> samples{};
        size_t count = 0, calls = 0, failures = 0;
        JSTIOwnedCapture *owner = nullptr;
        jsti::Handle entered, release;
        bool valid = true;
    };
    static std::mutex fixtureMutex;
    std::lock_guard<std::mutex> fixtureLock(fixtureMutex);
    // If real OS retirement fails, keep the callback context and event owners
    // alive too. A later explicit self-test invocation retries that same owner.
    static Check *retained = nullptr;
    const auto cleanup = [&](Check &check) {
        if (check.release.value) SetEvent(check.release.value);
        JSTIOwnedCaptureReceipt receipt{};
        receipt.size = sizeof(receipt);
        receipt.version = JSTI_OWNED_CAPTURE_VERSION;
        for (int attempt = 0; check.owner && attempt < 4; ++attempt) {
            jsti_owned_capture_retire(&check.owner, "fixture", &receipt, error, capacity);
        }
        return check.owner == nullptr;
    };
    if (retained) {
        if (!cleanup(*retained)) return ownedControlFailure("Earlier fixture ownership is still retained.", error, capacity);
        delete retained;
        retained = nullptr;
    }
    {
        JSTIOwnedCaptureReceipt receipt{};
        receipt.size = sizeof(receipt);
        receipt.version = JSTI_OWNED_CAPTURE_VERSION;
        char detail[128]{};
        if (jsti_owned_capture_retire(nullptr, "fixture", &receipt, detail, sizeof(detail)) != -1 || !detail[0]) {
            return ownedControlFailure("A missing retirement slot was not diagnosed.", error, capacity);
        }
    }
    const auto audio = [](const int16_t *samples, size_t count, void *value) {
        auto &check = *static_cast<Check *>(value);
        JSTIOwnedCaptureReceipt receipt{};
        receipt.size = sizeof(receipt);
        receipt.version = JSTI_OWNED_CAPTURE_VERSION;
        if (jsti_owned_capture_quiesce(check.owner, "fixture", &receipt, nullptr, 0) != -1) check.valid = false;
        if (check.entered.value) {
            SetEvent(check.entered.value);
            if (WaitForSingleObject(check.release.value, 3000) != WAIT_OBJECT_0) check.valid = false;
        }
        if (count != 73 || check.calls != 0) check.valid = false;
        if (count == 73) std::copy_n(samples, count, check.samples.data());
        check.count += count;
        ++check.calls;
    };
    const auto failed = [](const char *, void *value) { ++static_cast<Check *>(value)->failures; };
    for (uint32_t faults : {0u, 1u, 2u, 4u, 8u, 16u, 1u | 2u | 4u | 8u}) {
        auto state = std::make_unique<Check>();
        auto &check = *state;
        auto &owner = check.owner;
        JSTIOwnedCaptureReceipt receipt{};
        receipt.size = sizeof(receipt);
        receipt.version = JSTI_OWNED_CAPTURE_VERSION;
        const int opened = jsti_owned_capture_open_fixture(
            &owner, "fixture", faults, 24000, 100, audio, failed, &check, &receipt, error, capacity);
        bool valid = owner && (opened == 0) == !(faults & 16);
        valid = valid && jsti_owned_capture_quiesce(owner, "stale", &receipt, nullptr, 0) == -1;
        if (owner) {
            const int stopped = jsti_owned_capture_quiesce(owner, "fixture", &receipt, error, capacity);
            if (!(faults & (1u | 4u | 8u | 16u))) valid = valid && stopped == 0;
            else valid = valid && stopped == -1;
            // Faults are consumed once BEFORE a real signal/join. Retry still
            // performs the actual signal/join; the test never deletes instead.
            for (int attempt = 0; owner && attempt < 4; ++attempt) {
                jsti_owned_capture_retire(&owner, "fixture", &receipt, error, capacity);
            }
            if (owner) {
                retained = state.release();
                return ownedControlFailure("Fixture retirement failed; callback context remains retained.", error, capacity);
            }
            valid = valid && !owner && (receipt.flags & JSTI_OWNED_RESOURCES_RETIRED) &&
                (receipt.flags & JSTI_OWNED_CALLBACKS_DRAINED);
        }
        if (faults & 16) valid = valid && check.calls == 0 && check.failures == 1;
        else {
            valid = valid && check.calls == 1 && check.count == 73;
            for (size_t i = 0; i < check.samples.size(); ++i) valid = valid && check.samples[i] == i + 1;
        }
        if (faults & 8) valid = valid && check.failures == 1 && (receipt.flags & JSTI_OWNED_AUDIO_FAILED);
        if (!valid || !check.valid) return jsti::fail("Owned capture signal/join/partial/retry fixture failed.", error, capacity);
    }
    // A held LAST callback prevents acknowledgement, not just later free.
    auto state = std::make_unique<Check>();
    auto &check = *state;
    auto &owner = check.owner;
    auto &entered = check.entered;
    auto &release = check.release;
    entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    release.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!entered.value || !release.value) return jsti::fail("Could not create owned fixture gates.", error, capacity);
    JSTIOwnedCaptureReceipt receipt{};
    receipt.size = sizeof(receipt);
    receipt.version = JSTI_OWNED_CAPTURE_VERSION;
    if (jsti_owned_capture_open_fixture(
        &owner, "fixture", 0, 16000, 20, audio, failed, &check, &receipt, error, capacity) != 0) {
        if (!cleanup(check)) retained = state.release();
        return -1;
    }
    bool valid = false;
    std::future<int> stop;
    try {
        stop = std::async(std::launch::async, [&] {
            return jsti_owned_capture_quiesce(owner, "fixture", &receipt, error, capacity);
        });
        const bool arrived = WaitForSingleObject(entered.value, 3000) == WAIT_OBJECT_0;
        valid = arrived && stop.wait_for(std::chrono::milliseconds(20)) == std::future_status::timeout;
        SetEvent(release.value);
        valid = stop.get() == 0 && valid;
    } catch (...) {
        SetEvent(release.value);
        if (stop.valid()) stop.wait();
        valid = false;
    }
    const int retired = jsti_owned_capture_retire(&owner, "fixture", &receipt, error, capacity);
    if (owner) {
        retained = state.release();
        return ownedControlFailure("Held callback fixture retirement failed; callback context retained.", error, capacity);
    }
    if (!valid || retired != 0 || owner || !check.valid || check.calls != 1 || check.count != 73) {
        return jsti::fail("Owned final callback acknowledgement/retirement fixture failed.", error, capacity);
    }
    return 0;
}

namespace {
struct OwnedCapture {
    JSTICapture *value = nullptr;
    ~OwnedCapture() { jsti_capture_destroy(value); }
};

// Framing at one rate: coalescing into an exact full frame, an exact silent
// frame, a silence/source mix that subdivides a long packet, the partial stop
// flush, a repeated flush and zero-length no-ops. Sample order is verified.
int selfTestFraming(uint32_t sampleRate, uint32_t milliseconds, char *error, size_t capacity) {
    const size_t frame = frameSamplesFor(sampleRate, milliseconds);
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
    Frames frames(sampleRate, callback, &check, milliseconds);
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

// Three full wraps at each format prove a 12.8-second queue, overflow refusal,
// FIFO order, silence and a partial tail without depending on worker scheduling.
int selfTestRing(uint32_t sampleRate, uint32_t milliseconds, char *error, size_t capacity) {
    static_assert(PCMFrameRing::storageSamples * sizeof(int16_t) == 614400);
    auto ring = std::make_unique<PCMFrameRing>(sampleRate, milliseconds);
    std::vector<int16_t> data(ring->slotSamples);
    if (ring->slotCount * milliseconds != bufferedMilliseconds ||
        ring->slotCount * ring->slotSamples != sampleRate * bufferedMilliseconds / 1000 ||
        ring->push(data.data(), 0) || ring->push(data.data(), data.size() + 1)) {
        return jsti::fail("The PCM queue time budget or frame bound is incorrect.", error, capacity);
    }
    for (size_t pass = 0; pass < 3; ++pass) {
        for (size_t index = 0; index < ring->slotCount; ++index) {
            std::fill(data.begin(), data.end(), static_cast<int16_t>(pass * ring->slotCount + index + 1));
            const size_t count = index + 1 == ring->slotCount ? 99 : data.size();
            if (!ring->push(index % 3 == 0 ? nullptr : data.data(), count)) {
                return jsti::fail("The PCM queue rejected a frame before capacity.", error, capacity);
            }
        }
        if (ring->push(data.data(), 1) || ring->push(data.data(), data.size())) {
            return jsti::fail("The PCM queue exceeded its fixed capacity.", error, capacity);
        }
        for (size_t index = 0; index < ring->slotCount; ++index) {
            const auto *frame = ring->front();
            const size_t count = index + 1 == ring->slotCount ? 99 : data.size();
            const int16_t expected = index % 3 == 0 ? 0
                : static_cast<int16_t>(pass * ring->slotCount + index + 1);
            if (!frame || frame->count != count ||
                !std::all_of(frame->samples, frame->samples + count,
                             [expected](int16_t value) { return value == expected; })) {
                return jsti::fail("PCM queue FIFO, silence, wrap or partial-frame check failed.", error, capacity);
            }
            ring->pop();
        }
        if (ring->front()) return jsti::fail("The PCM queue did not drain completely.", error, capacity);
    }
    return 0;
}

// Synthetic packet arrival times isolate the batching added by this code from
// driver, scheduling, networking or provider latency. Test both driver packet
// sizes at both sample rates, preserving every sample and the final short tail.
int selfTestArrivalLatency(uint32_t sampleRate, uint32_t milliseconds, uint32_t packetMilliseconds,
                           char *error, size_t capacity) {
    struct Check {
        size_t target, packet, delivered = 0, calls = 0;
        uint32_t packetMilliseconds, now = 0, firstDelivery = 0, longestWait = 0;
        bool flushing = false, valid = true;
    } check{frameSamplesFor(sampleRate, milliseconds), frameSamplesFor(sampleRate, packetMilliseconds),
            0, 0, packetMilliseconds};
    auto callback = [](const int16_t *data, size_t count, void *context) {
        auto &state = *static_cast<Check *>(context);
        if (!state.calls) state.firstDelivery = state.now;
        if (!count || count > state.target || (!state.flushing && count != state.target)) state.valid = false;
        for (size_t index = 0; index < count; ++index) {
            if (data[index] != static_cast<int16_t>((state.delivered + index) % 30000 + 1)) state.valid = false;
        }
        // The first sample in this frame arrived with its containing packet.
        if (!state.flushing) {
            const auto firstArrival = static_cast<uint32_t>((state.delivered / state.packet + 1) *
                state.packetMilliseconds);
            state.longestWait = std::max(state.longestWait, state.now - firstArrival);
        }
        state.delivered += count;
        ++state.calls;
    };
    Frames frames(sampleRate, callback, &check, milliseconds);
    std::vector<int16_t> packet(check.packet);
    const size_t fullPackets = 200 / packetMilliseconds;
    for (size_t index = 0; index < fullPackets; ++index) {
        for (size_t sample = 0; sample < packet.size(); ++sample) {
            packet[sample] = static_cast<int16_t>((index * packet.size() + sample) % 30000 + 1);
        }
        check.now = static_cast<uint32_t>((index + 1) * packetMilliseconds);
        frames.append(packet.data(), packet.size());
    }
    if (!check.valid || check.firstDelivery != milliseconds || check.calls != 200 / milliseconds ||
        check.delivered != sampleRate / 5 || check.longestWait != milliseconds - packetMilliseconds) {
        return jsti::fail("Synthetic packet arrival-to-frame delivery or ordering failed.", error, capacity);
    }
    const size_t tail = sampleRate / 200; // 5 ms, always shorter than either frame duration.
    for (size_t sample = 0; sample < tail; ++sample) {
        packet[sample] = static_cast<int16_t>((sampleRate / 5 + sample) % 30000 + 1);
    }
    check.now = 205;
    frames.append(packet.data(), tail);
    if (check.calls != 200 / milliseconds) return jsti::fail("A partial frame escaped before stop.", error, capacity);
    check.flushing = true;
    frames.flush();
    frames.flush();
    if (!check.valid || check.calls != 200 / milliseconds + 1 || check.delivered != sampleRate / 5 + tail) {
        return jsti::fail("Synthetic stop lost, duplicated or padded the final partial frame.", error, capacity);
    }
    return 0;
}

// Writer drain at one frame size: a full frame, a full silent frame and a
// partial frame all reach the callback intact before finish returns; a second
// finish is harmless and later appends are rejected.
int selfTestWriter(uint32_t sampleRate, uint32_t milliseconds, char *error, size_t capacity) {
    struct Check { size_t frame = 0; size_t calls = 0; bool valid = true; } written;
    written.frame = frameSamplesFor(sampleRate, milliseconds);
    auto callback = [](const int16_t *data, size_t count, void *context) {
        auto &state = *static_cast<Check *>(context);
        const size_t expectedCount = state.calls == 2 ? 99 : state.frame;
        const int16_t expected = state.calls == 1 ? 0 : 42;
        if (count != expectedCount || !std::all_of(data, data + count,
            [expected](int16_t value) { return value == expected; })) state.valid = false;
        ++state.calls;
    };
    std::vector<int16_t> data(written.frame, int16_t{42});
    BufferedAudioWriter writer(callback, &written, nullptr, sampleRate, milliseconds);
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
    for (const uint32_t milliseconds : {0u, 1u, 19u, 21u, 50u, 99u, 101u, UINT32_MAX}) {
        detail[0] = 0;
        OwnedCapture rejected{jsti_capture_create_with_options("", defaultSampleRate, milliseconds,
            audio, failed, &callbacks, detail, sizeof(detail))};
        if (rejected.value || !detail[0]) {
            return jsti::fail("An unsupported frame duration was accepted or left unreported.", error, capacity);
        }
    }
    for (const uint32_t rate : {defaultSampleRate, maximumSampleRate}) {
        for (const uint32_t milliseconds : {minimumFrameMilliseconds, defaultFrameMilliseconds}) {
            stale();
            OwnedCapture configured{jsti_capture_create_with_options("", rate, milliseconds,
                audio, failed, &callbacks, detail, sizeof(detail))};
            if (!configured.value || detail[0] || configured.value->sampleRate != rate ||
                configured.value->frameMilliseconds != milliseconds) {
                return jsti::fail("The explicit capture frame format was not retained.", error, capacity);
            }
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
        legacyDevice.value->sampleRate != defaultSampleRate ||
        formatted.value->frameMilliseconds != defaultFrameMilliseconds ||
        legacy.value->frameMilliseconds != defaultFrameMilliseconds ||
        legacyDevice.value->frameMilliseconds != defaultFrameMilliseconds ||
        realtime.value->frameMilliseconds != defaultFrameMilliseconds || !formatted.value->deviceIdentifier.empty() ||
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
            for (const uint32_t milliseconds : {minimumFrameMilliseconds, defaultFrameMilliseconds}) {
                if (selfTestFraming(sampleRate, milliseconds, error, capacity) ||
                    selfTestRing(sampleRate, milliseconds, error, capacity) ||
                    selfTestWriter(sampleRate, milliseconds, error, capacity)) return -1;
                for (const uint32_t packetMilliseconds : {10u, 20u}) {
                    if (selfTestArrivalLatency(sampleRate, milliseconds, packetMilliseconds, error, capacity)) return -1;
                }
            }
        }
        if (selfTestCreation(error, capacity)) return -1;
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
