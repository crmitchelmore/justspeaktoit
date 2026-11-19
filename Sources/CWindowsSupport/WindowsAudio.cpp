#include "WindowsAudioCaptureInternal.hpp"

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

namespace jsti_audio {
thread_local const JSTICapture *activeCaptureCallback = nullptr;
} // namespace jsti_audio

using namespace jsti_audio;

namespace {
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
} // namespace

void JSTICapture::run(std::promise<std::string> ready) {
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

namespace jsti_audio {
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
} // namespace jsti_audio

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
