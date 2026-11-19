// Private to the WASAPI capture units (WindowsAudio.cpp, WindowsOwnedCapture.cpp) and
// their self-test: the frame format, the bounded PCM ring and writer, owned-capture
// control and the capture object. Never part of the C ABI.
#pragma once
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

namespace jsti_audio {
// Identifies callbacks on both capture and writer threads without shared mutable
// thread IDs. A callback must never join its own capture/writer lifecycle.
extern thread_local const JSTICapture *activeCaptureCallback;
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
inline size_t validatedFrameSamples(uint32_t sampleRate, uint32_t milliseconds) {
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

// Shared constructor: validates the callback, rate and identifier without
// touching any device. Hardware is only activated by jsti_capture_start.
JSTICapture *createCapture(const char *deviceID, uint32_t sampleRate, uint32_t frameMilliseconds,
                           JSTIAudioCallback callback,
                           JSTIAudioErrorCallback errorCallback, void *context, char *error, size_t errorCapacity);
// Copies `message` into `error` and returns -1; never allocates.
int ownedControlFailure(const char *message, char *error, size_t capacity) noexcept;
} // namespace jsti_audio

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
    jsti_audio::OwnedCaptureControl *owned = nullptr;

    JSTICapture(JSTIAudioCallback callback, JSTIAudioErrorCallback errorCallback, void *context,
                std::wstring deviceIdentifier, uint32_t sampleRate, uint32_t frameMilliseconds)
        : callback(callback), errorCallback(errorCallback), context(context),
          deviceIdentifier(std::move(deviceIdentifier)), sampleRate(sampleRate), frameMilliseconds(frameMilliseconds) {}

    // The capture thread: WASAPI activation, framing and the writer (WindowsAudio.cpp).
    void run(std::promise<std::string> ready);
};
static_assert(std::is_const_v<decltype(JSTICapture::sampleRate)> &&
              std::is_const_v<decltype(JSTICapture::frameMilliseconds)>, "The capture format must be immutable.");
