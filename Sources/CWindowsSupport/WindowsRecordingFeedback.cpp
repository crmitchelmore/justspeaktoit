#include "CWindowsSupport.h"
#include "WindowsPlaybackInternal.hpp"
#include <cmath>
#include <exception>
#include <stdexcept>

namespace {
using namespace jsti::playback;
constexpr uint64_t fileLimit = 1 << 20;
constexpr uint64_t pcmLimit = 16 << 20;
constexpr unsigned durationLimit = 5;

std::string exceptionMessage() {
    try { throw; }
    catch (const Failure &failure) { return describe(failure); }
    catch (const Cancelled &) { return "Recording feedback preparation cancelled."; }
    catch (const std::exception &error) { return std::string("Recording feedback: ") + error.what(); }
    catch (...) { return "Unexpected recording feedback native failure."; }
}

// Float format is negotiated explicitly before this is used; never interpret
// an endpoint's integer mix bytes as float. Padding is zeroed, not gain-scaled.
void fillPCM(BYTE *destination, UINT32 frames, uint32_t channels,
             const std::vector<float> &pcm, size_t &position, float gain) noexcept {
    const size_t count = size_t{frames} * channels;
    const size_t copied = std::min(count, pcm.size() - position);
    for (size_t index = 0; index < copied; ++index) {
        const float value = pcm[position + index] * gain;
        std::memcpy(destination + index * sizeof(float), &value, sizeof(value));
    }
    std::memset(destination + copied * sizeof(float), 0, (count - copied) * sizeof(float));
    position += copied;
}

void decode(Decoder &decoder, const FormatSpec &format, std::vector<float> &pcm,
            const std::atomic<bool> &cancelled) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(durationLimit);
    const uint64_t limit = std::min(pcmLimit, format.byteRate() * durationLimit);
    const int64_t duration = decoder.durationTicks();
    if (duration > int64_t{durationLimit} * 10000000) {
        throw Failure{E_INVALIDARG, "Recording feedback exceeds five seconds"};
    }
    while (decoder.next([&](const uint8_t *data, size_t size) {
        if (cancelled.load()) throw Cancelled{};
        if (std::chrono::steady_clock::now() >= deadline) {
            throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Decode recording feedback within five seconds"};
        }
        if (size % format.blockAlign || size > limit || pcm.size() * sizeof(float) > limit - size) {
            throw Failure{E_INVALIDARG, "Recording feedback exceeds bounded whole-frame PCM storage"};
        }
        const size_t before = pcm.size();
        pcm.resize(before + size / sizeof(float));
        std::memcpy(pcm.data() + before, data, size);
        for (size_t index = before; index < pcm.size(); ++index) {
            if (!std::isfinite(pcm[index])) throw Failure{E_INVALIDARG, "Nonfinite recording feedback PCM"};
        }
    })) {
        if (std::chrono::steady_clock::now() >= deadline) {
            throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Decode recording feedback within five seconds"};
        }
    }
    if (pcm.empty()) throw Failure{E_INVALIDARG, "Recording feedback has no decoded audio"};
}

void openDecoder(Decoder &decoder, const std::wstring &path) {
    jsti::Handle source;
    uint64_t size = 0;
    openSource(path, fileLimit, source, size);
    decoder.open(source, size, path);
}
} // namespace

struct JSTIRecordingFeedback {
    JSTIRecordingFeedbackFailure callback = nullptr;
    void *context = nullptr;
    jsti::Handle command;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> closing{false};
    std::mutex readMutex;
    std::shared_ptr<ReadState> read = std::make_shared<ReadState>();
    std::thread worker;
    std::mutex mutex;
    std::condition_variable changed;
    bool launched = false, prepared = false, ended = false;
    uint64_t generation = 0;
    int requested = -1;
    float gain = 0;
    std::chrono::steady_clock::time_point admitted{};
    double firstBufferLatency = 0;
    bool awaitingFirstBuffer = false;
    bool stopAcknowledged = false;
    std::string failure;
    std::string cleanupFailure;

    void cancel() {
        // The predicate and notification share the read mutex to avoid losing
        // cancellation between a source reader's check and its wait.
        {
            std::lock_guard<std::mutex> owner(readMutex);
            std::lock_guard<std::mutex> lock(read->mutex);
            cancelled.store(true);
            read->changed.notify_all();
        }
        SetEvent(command.value);
    }

    void render(RenderOutput &output, const FormatSpec &format, const std::vector<float> (&pcm)[2]) {
        uint64_t observed = 0;
        size_t position = 0;
        int cue = -1;
        HANDLE events[] = {command.value, output.event()};
        // The dedicated stream stays started, emitting silence while idle.
        // Warm play/stop only change this PCM mailbox: no COM calls, device
        // starts, waits, allocation or decoder work on the calling thread.
        while (!closing.load()) {
            UINT32 padding = 0;
            require(output.padding(padding), "Read recording feedback output padding");
            const UINT32 frames = output.bufferFrames();
            if (padding > frames) throw Failure{AUDCLNT_E_BUFFER_ERROR, "Invalid feedback output padding"};
            if (frames > padding) {
                BYTE *destination = nullptr;
                require(output.acquire(frames - padding, &destination), "Acquire recording feedback buffer");
                uint64_t submittedGeneration = 0;
                bool firstBuffer = false, stopSilence = false;
                {
                    // Only bounded memory copies under the command lock; never
                    // hold it across an endpoint/codec/driver operation.
                    std::lock_guard<std::mutex> lock(mutex);
                    if (observed != generation || closing.load()) {
                        observed = generation;
                        cue = closing.load() ? -1 : requested;
                        position = 0;
                    }
                    submittedGeneration = observed;
                    if (cue >= 0) {
                        firstBuffer = position == 0 && awaitingFirstBuffer;
                        fillPCM(destination, frames - padding, format.channels, pcm[cue], position, gain);
                        if (position == pcm[cue].size()) cue = -1;
                    } else {
                        stopSilence = requested < 0;
                        std::memset(destination, 0, size_t{frames - padding} * format.blockAlign);
                    }
                }
                require(output.release(frames - padding), "Submit recording feedback buffer");
                const auto released = std::chrono::steady_clock::now();
                if (firstBuffer || stopSilence) {
                    std::lock_guard<std::mutex> lock(mutex);
                    // ReleaseBuffer stays outside the command lock. A stop or
                    // newer play admitted meanwhile invalidates this witness.
                    if (generation == submittedGeneration && !closing.load()) {
                        if (firstBuffer && awaitingFirstBuffer) {
                            firstBufferLatency = std::max(1e-9, std::chrono::duration<double>(released - admitted).count());
                            awaitingFirstBuffer = false;
                        }
                        if (stopSilence && requested < 0) stopAcknowledged = true;
                        changed.notify_all();
                    }
                }
            }
            const DWORD result = WaitForMultipleObjects(2, events, FALSE, 2000);
            if (result == WAIT_TIMEOUT) throw Failure{HRESULT_FROM_WIN32(ERROR_TIMEOUT), "Recording feedback output event"};
            if (result != WAIT_OBJECT_0 && result != WAIT_OBJECT_0 + 1) {
                throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Wait for recording feedback output"};
            }
        }
    }

    void run(const std::wstring &start, const std::wstring &stop) noexcept {
        std::string error;
        try {
            MediaPlatform platform;
            platform.initialise();
            std::unique_ptr<RenderOutput> output;
            std::vector<float> pcm[2];
            FormatSpec format;
            try {
                const std::wstring paths[] = {start, stop};
                for (unsigned index = 0; index < 2; ++index) {
                    if (cancelled.load()) throw Cancelled{};
                    // ReaderResources permanently closes its ReadState; a
                    // second decoder therefore needs a fresh callback state.
                    auto state = std::make_shared<ReadState>();
                    { std::lock_guard<std::mutex> lock(readMutex); read = state; }
                    Decoder decoder(cancelled, state, 2);
                    try {
                        openDecoder(decoder, paths[index]);
                        if (!index) output = openFeedbackOutput(decoder, format);
                        else require(decoder.configure(format, 1 << 20), "Decode second feedback cue as float PCM");
                        decode(decoder, format, pcm[index], cancelled);
                        decoder.close();
                    } catch (...) {
                        std::string original = exceptionMessage();
                        try { decoder.close(); }
                        catch (...) { original += " Cleanup: " + exceptionMessage(); }
                        throw std::runtime_error(original);
                    }
                }
                if (cancelled.load()) throw Cancelled{};
                BYTE *silence = nullptr;
                require(output->acquire(output->bufferFrames(), &silence), "Prime recording feedback output");
                std::memset(silence, 0, size_t{output->bufferFrames()} * format.blockAlign);
                require(output->release(output->bufferFrames()), "Submit recording feedback silence");
                require(output->start(), "Start warm recording feedback output");
                {
                    std::lock_guard<std::mutex> lock(mutex);
                    prepared = true;
                    changed.notify_all();
                }
                render(*output, format, pcm);
            } catch (...) {
                error = exceptionMessage();
                std::lock_guard<std::mutex> lock(mutex);
                failure = error;
                firstBufferLatency = -1;
                awaitingFirstBuffer = false;
                stopAcknowledged = false;
                changed.notify_all();
            }
            if (output) {
                const HRESULT stopped = output->stop();
                const HRESULT reset = output->reset();
                if (FAILED(stopped) || FAILED(reset)) {
                    cleanupFailure = describe(Failure{FAILED(stopped) ? stopped : reset, "Close recording feedback output"});
                    if (error.empty()) error = cleanupFailure;
                    else error += " Cleanup: " + cleanupFailure;
                }
                output.reset();
            }
            // Explicit MF shutdown surfaces errors; the shared destructor is
            // only a best-effort safeguard.
            if (platform.media) {
                const HRESULT shutdown = MediaAPI::shared().stop();
                platform.media = false;
                if (FAILED(shutdown)) {
                    const auto message = describe(Failure{shutdown, "Close recording feedback Media Foundation"});
                    cleanupFailure += (cleanupFailure.empty() ? "" : " ") + message;
                    error += (error.empty() ? "" : " Cleanup: ") + message;
                }
            }
        } catch (...) { error = exceptionMessage(); }
        bool notify = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            failure = error;
            if (!error.empty()) firstBufferLatency = -1;
            awaitingFirstBuffer = false;
            notify = prepared && !error.empty();
            ended = true;
            changed.notify_all();
        }
        if (notify && callback) callback(error.c_str(), context);
    }
};

JSTIRecordingFeedback *jsti_recording_feedback_create(
    JSTIRecordingFeedbackFailure callback, void *context, char *error, size_t capacity
) {
    try {
        auto feedback = std::make_unique<JSTIRecordingFeedback>();
        feedback->callback = callback;
        feedback->context = context;
        feedback->command.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!feedback->command.value) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Create feedback command event"};
        return feedback.release();
    } catch (...) { jsti::fail(exceptionMessage(), error, capacity); return nullptr; }
}

int jsti_recording_feedback_prepare(JSTIRecordingFeedback *feedback, const char *start, const char *stop,
                                    char *error, size_t capacity) {
    if (!feedback) return jsti::fail("Invalid recording feedback channel.", error, capacity);
    try {
        std::wstring paths[2];
        if (!localPath(start, paths[0]) || !localPath(stop, paths[1])) {
            return jsti::fail("Recording feedback requires two local asset paths.", error, capacity);
        }
        std::unique_lock<std::mutex> lock(feedback->mutex);
        if (feedback->launched || feedback->closing.load()) {
            return jsti::fail("Recording feedback can be prepared only once.", error, capacity);
        }
        feedback->launched = true;
        feedback->worker = std::thread([feedback, paths] { feedback->run(paths[0], paths[1]); });
        const bool finished = feedback->changed.wait_for(lock, std::chrono::seconds(20), [&] {
            return feedback->prepared || feedback->ended;
        });
        if (!finished) {
            lock.unlock();
            feedback->cancel();
            return jsti::fail("Recording feedback preparation timed out.", error, capacity);
        }
        if (!feedback->prepared || feedback->ended || feedback->cancelled.load()) {
            return jsti::fail(feedback->failure.empty() ? "Recording feedback preparation cancelled." : feedback->failure,
                              error, capacity);
        }
        return 0;
    } catch (...) { return jsti::fail(exceptionMessage(), error, capacity); }
}

void jsti_recording_feedback_cancel_preparation(JSTIRecordingFeedback *feedback) {
    if (feedback) feedback->cancel();
}

int jsti_recording_feedback_play(JSTIRecordingFeedback *feedback, int cue, float gain, char *error, size_t capacity) {
    if (!feedback || cue < 0 || cue > 1 || !std::isfinite(gain) || gain < 0 || gain > 1) {
        return jsti::fail("Invalid recording feedback cue or gain.", error, capacity);
    }
    std::lock_guard<std::mutex> lock(feedback->mutex);
    if (!feedback->prepared || feedback->ended || feedback->closing.load() || feedback->cancelled.load() ||
        !feedback->failure.empty()) {
        return jsti::fail(feedback->failure.empty() ? "Recording feedback channel is not ready." : feedback->failure,
                          error, capacity);
    }
    feedback->requested = cue;
    feedback->gain = gain;
    feedback->admitted = std::chrono::steady_clock::now();
    feedback->firstBufferLatency = 0;
    feedback->awaitingFirstBuffer = true;
    feedback->stopAcknowledged = false;
    ++feedback->generation;
    SetEvent(feedback->command.value);
    return 0;
}

double jsti_recording_feedback_first_buffer_latency(JSTIRecordingFeedback *feedback, char *error, size_t capacity) {
    if (!feedback) return jsti::fail("Invalid recording feedback channel.", error, capacity);
    std::lock_guard<std::mutex> lock(feedback->mutex);
    if (!feedback->failure.empty()) return jsti::fail(feedback->failure, error, capacity);
    if (!feedback->prepared || feedback->ended || feedback->closing.load() || feedback->cancelled.load()) {
        return jsti::fail("Recording feedback channel is not ready.", error, capacity);
    }
    if (feedback->firstBufferLatency < 0) {
        return jsti::fail("Recording feedback cue stopped before its first buffer was queued.", error, capacity);
    }
    return feedback->firstBufferLatency;
}

void jsti_recording_feedback_stop(JSTIRecordingFeedback *feedback) {
    if (!feedback) return;
    std::lock_guard<std::mutex> lock(feedback->mutex);
    feedback->requested = -1;
    if (feedback->awaitingFirstBuffer) feedback->firstBufferLatency = -1;
    feedback->awaitingFirstBuffer = false;
    feedback->stopAcknowledged = false;
    ++feedback->generation;
    SetEvent(feedback->command.value);
}

int jsti_recording_feedback_stop_acknowledged(JSTIRecordingFeedback *feedback, char *error, size_t capacity) {
    if (!feedback) return jsti::fail("Invalid recording feedback channel.", error, capacity);
    std::lock_guard<std::mutex> lock(feedback->mutex);
    if (!feedback->failure.empty()) return jsti::fail(feedback->failure, error, capacity);
    if (!feedback->prepared || feedback->ended || feedback->closing.load() || feedback->cancelled.load()) {
        return jsti::fail("Recording feedback channel is not ready.", error, capacity);
    }
    return feedback->requested < 0 && feedback->stopAcknowledged ? 1 : 0;
}

int jsti_recording_feedback_destroy(JSTIRecordingFeedback *feedback, char *error, size_t capacity) {
    if (!feedback) return 0;
    feedback->closing.store(true);
    feedback->cancel();
    // No timeout/detach: the opaque state and callback context remain owned
    // until the worker has actually released every COM object and returned.
    if (feedback->worker.joinable()) feedback->worker.join();
    const std::string cleanup = feedback->cleanupFailure;
    delete feedback;
    return cleanup.empty() ? 0 : jsti::fail(cleanup, error, capacity);
}

namespace {
// Drives the actual resident rendering loop with no endpoint. Fake events are
// explicit, so tests need neither sleeps nor guessed device-consumption timing.
class FeedbackTestOutput final : public RenderOutput {
    jsti::Handle renderEvent;
    float buffer[4]{};
    std::mutex mutex;
    std::vector<float> delivered;
public:
    jsti::Handle audible;
    jsti::Handle quiet;
    std::atomic<HRESULT> paddingFailure{S_OK};
    FeedbackTestOutput() {
        renderEvent.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        audible.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        quiet.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!renderEvent.value || !audible.value || !quiet.value) {
            throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Create feedback renderer test events"};
        }
    }
    HANDLE event() const noexcept override { return renderEvent.value; }
    UINT32 bufferFrames() const noexcept override { return 2; }
    HRESULT start() noexcept override { return S_OK; }
    HRESULT stop() noexcept override { return S_OK; }
    HRESULT reset() noexcept override { return S_OK; }
    HRESULT padding(UINT32 &frames) noexcept override { frames = 0; return paddingFailure.load(); }
    HRESULT acquire(UINT32 frames, BYTE **data) noexcept override {
        if (frames != 2) return E_INVALIDARG;
        *data = reinterpret_cast<BYTE *>(buffer);
        return S_OK;
    }
    HRESULT release(UINT32 frames) noexcept override {
        if (frames != 2) return E_INVALIDARG;
        if (buffer[0] || buffer[1] || buffer[2] || buffer[3]) {
            { std::lock_guard<std::mutex> lock(mutex); std::copy(buffer, buffer + 4, delivered.begin()); }
            SetEvent(audible.value);
        } else { SetEvent(quiet.value); }
        return S_OK;
    }
    REFERENCE_TIME latency() noexcept override { return 0; }
    void allocate() { delivered.resize(4); }
    void expect(const std::vector<float> &values) {
        if (WaitForSingleObject(audible.value, 2000) != WAIT_OBJECT_0) {
            throw Failure{E_FAIL, "Feedback renderer self-test did not deliver a cue"};
        }
        std::lock_guard<std::mutex> lock(mutex);
        if (delivered != values) throw Failure{E_FAIL, "Feedback renderer self-test delivered incorrect PCM"};
    }
};

void rendererSelfTest() {
    JSTIRecordingFeedback feedback;
    feedback.command.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!feedback.command.value) throw Failure{HRESULT_FROM_WIN32(GetLastError()), "Create feedback test command"};
    FeedbackTestOutput output;
    output.allocate();
    const FormatSpec format = floatFormat(48000, 2, stereoMask);
    const std::vector<float> pcm[2] = {{1, -1, 0.5f, -0.5f}, {0.5f, -0.5f, 1, -1}};
    feedback.prepared = true;
    char error[1024]{};
    auto awaitWitness = [&](bool stopped) {
        std::unique_lock<std::mutex> lock(feedback.mutex);
        const bool ready = feedback.changed.wait_for(lock, std::chrono::seconds(2), [&] {
            return !feedback.failure.empty() || (stopped ? feedback.stopAcknowledged : feedback.firstBufferLatency > 0);
        });
        lock.unlock();
        if (!ready) throw Failure{E_FAIL, "Feedback renderer did not publish its release witness"};
        if (stopped) {
            if (jsti_recording_feedback_stop_acknowledged(&feedback, error, sizeof(error)) != 1) {
                throw Failure{E_FAIL, "Feedback stop acknowledgement self-test"};
            }
        } else {
            const double latency = jsti_recording_feedback_first_buffer_latency(&feedback, error, sizeof(error));
            if (!std::isfinite(latency) || latency <= 0) {
                throw Failure{E_FAIL, "Feedback first-buffer latency self-test"};
            }
        }
    };
    if (jsti_recording_feedback_play(&feedback, 0, 1, error, sizeof(error))) throw std::runtime_error(error);
    if (jsti_recording_feedback_first_buffer_latency(&feedback, error, sizeof(error)) != 0) {
        throw Failure{E_FAIL, "Feedback latency was published before any buffer was released"};
    }
    jsti_recording_feedback_stop(&feedback);
    if (jsti_recording_feedback_first_buffer_latency(&feedback, error, sizeof(error)) != -1) {
        throw Failure{E_FAIL, "Feedback pending-cue cancellation latency self-test"};
    }
    feedback.worker = std::thread([&] {
        try { feedback.render(output, format, pcm); }
        catch (...) {
            std::lock_guard<std::mutex> lock(feedback.mutex);
            feedback.failure = exceptionMessage();
        }
    });
    struct Join {
        JSTIRecordingFeedback &feedback;
        ~Join() {
            feedback.closing.store(true);
            SetEvent(feedback.command.value);
            if (feedback.worker.joinable()) feedback.worker.join();
        }
    } join{feedback};
    if (WaitForSingleObject(output.quiet.value, 2000) != WAIT_OBJECT_0 ||
        WaitForSingleObject(output.audible.value, 0) != WAIT_TIMEOUT) {
        throw Failure{E_FAIL, "Feedback stop failed to discard a pending cue"};
    }
    awaitWitness(true);
    if (jsti_recording_feedback_play(&feedback, 0, 0.25f, error, sizeof(error))) {
        throw std::runtime_error(error);
    }
    output.expect({0.25f, -0.25f, 0.125f, -0.125f});
    awaitWitness(false);
    ResetEvent(output.quiet.value);
    jsti_recording_feedback_stop(&feedback);
    if (WaitForSingleObject(output.quiet.value, 2000) != WAIT_OBJECT_0) {
        throw Failure{E_FAIL, "Feedback stop self-test did not emit silence"};
    }
    awaitWitness(true);
    if (jsti_recording_feedback_play(&feedback, 0, 1, error, sizeof(error))) throw std::runtime_error(error);
    output.expect({1, -1, 0.5f, -0.5f});
    awaitWitness(false);
    if (jsti_recording_feedback_play(&feedback, 1, 0.5f, error, sizeof(error))) throw std::runtime_error(error);
    output.expect({0.25f, -0.25f, 0.5f, -0.5f});
    awaitWitness(false);
    jsti_recording_feedback_stop(&feedback);
    if (!jsti_recording_feedback_play(&feedback, 0, NAN, error, sizeof(error))) {
        throw Failure{E_FAIL, "Feedback self-test admitted nonfinite gain"};
    }
    feedback.closing.store(true);
    SetEvent(feedback.command.value);
    feedback.worker.join();
    if (!feedback.failure.empty()) throw std::runtime_error(feedback.failure);
    feedback.closing.store(false);
    output.paddingFailure.store(AUDCLNT_E_DEVICE_INVALIDATED);
    HRESULT loss = S_OK;
    feedback.worker = std::thread([&] {
        try { feedback.render(output, format, pcm); }
        catch (const Failure &failure) { loss = failure.code; }
        catch (...) { loss = E_UNEXPECTED; }
    });
    feedback.worker.join();
    if (loss != AUDCLNT_E_DEVICE_INVALIDATED) {
        throw Failure{E_FAIL, "Feedback renderer did not surface device loss"};
    }
}
} // namespace

int jsti_recording_feedback_renderer_self_test(char *error, size_t capacity) {
    try {
        rendererSelfTest();
        return 0;
    } catch (...) { return jsti::fail(exceptionMessage(), error, capacity); }
}

namespace {
void checkAssetCodecs(const char *const *paths, size_t count) {
    MediaPlatform platform;
    platform.initialise();
    std::string error;
    try {
        const FormatSpec format = floatFormat(48000, 2, stereoMask);
        std::atomic<bool> cancelled{false};
        for (size_t index = 0; index < count; ++index) {
            std::wstring path;
            if (!localPath(paths[index], path)) throw Failure{E_INVALIDARG, "Invalid feedback test path"};
            auto read = std::make_shared<ReadState>();
            Decoder decoder(cancelled, read, 2);
            try {
                openDecoder(decoder, path);
                require(decoder.configure(format, 1 << 20), "Decode bundled feedback test asset");
                std::vector<float> pcm;
                decode(decoder, format, pcm, cancelled);
                decoder.close();
            } catch (...) {
                std::string original = exceptionMessage();
                try { decoder.close(); }
                catch (...) { original += " Cleanup: " + exceptionMessage(); }
                throw std::runtime_error(original);
            }
        }
    } catch (...) { error = exceptionMessage(); }
    const HRESULT shutdown = MediaAPI::shared().stop();
    platform.media = false;
    if (FAILED(shutdown)) {
        error += (error.empty() ? "" : " Cleanup: ") +
                 describe(Failure{shutdown, "Close feedback codec check Media Foundation"});
    }
    if (!error.empty()) throw std::runtime_error(error);
}
} // namespace

int jsti_recording_feedback_check_assets(const char *start, const char *stop, char *error, size_t capacity) {
    if (!start || !stop) return jsti::fail("Provide both feedback profile assets.", error, capacity);
    try {
        const char *paths[] = {start, stop};
        checkAssetCodecs(paths, 2);
        return 2;
    } catch (...) { return jsti::fail(exceptionMessage(), error, capacity); }
}

int jsti_recording_feedback_self_test(const char *const *paths, size_t count, char *error, size_t capacity) {
    if (!paths || count != 8) return jsti::fail("Provide all eight bundled feedback assets.", error, capacity);
    try {
        checkAssetCodecs(paths, count);
        const std::vector<float> pcm{1, -1, 0.5f, -0.5f};
        float rendered[6]{};
        size_t position = 0;
        fillPCM(reinterpret_cast<BYTE *>(rendered), 3, 2, pcm, position, 0.25f);
        if (position != 4 || rendered[0] != 0.25f || rendered[1] != -0.25f ||
            rendered[2] != 0.125f || rendered[3] != -0.125f || rendered[4] || rendered[5]) {
            throw Failure{E_FAIL, "Feedback gain and silent padding self-test"};
        }
        position = 0;
        fillPCM(reinterpret_cast<BYTE *>(rendered), 1, 2, pcm, position, 1);
        if (position != 2 || rendered[0] != 1 || rendered[1] != -1) {
            throw Failure{E_FAIL, "Feedback sample-zero replay self-test"};
        }
        rendererSelfTest();
        return 0;
    } catch (...) { return jsti::fail(exceptionMessage(), error, capacity); }
}
