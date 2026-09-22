#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <avrt.h>
#include <array>
#include <future>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

namespace {
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
                if (errorCallback) errorCallback(message.c_str(), context);
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
            Frames frames(callback, context);
            jsti::COM<IAudioCaptureClient> reader;
            result = client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void **>(&reader.value));
            if (FAILED(result)) { report(audioError("Opening microphone capture stream", result)); return; }
            Scheduling scheduling;
            if (!scheduling.handle) { report(jsti::systemError("Scheduling microphone audio thread")); return; }
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
    if (capture->worker.joinable() && capture->worker.get_id() == std::this_thread::get_id()) return;
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
    JSTITextTarget target{};
    char expectedError[256]{};
    if (jsti_target_insert_text(&target, "must not be inserted", expectedError, sizeof(expectedError)) != -1) {
        return jsti::fail("Invalid text target was not rejected.", error, capacity);
    }
    return 0;
}
