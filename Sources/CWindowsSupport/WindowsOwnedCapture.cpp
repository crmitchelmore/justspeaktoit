// Owned capture: a run-scoped WASAPI capture whose quiesce and retirement are
// acknowledged through receipts, so callbacks never outlive their owner.
#include "WindowsAudioCaptureInternal.hpp"

using namespace jsti_audio;

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

namespace jsti_audio {
int ownedControlFailure(const char *message, char *error, size_t capacity) noexcept {
    if (error && capacity) {
        const size_t count = std::min(std::strlen(message), capacity - 1);
        std::memcpy(error, message, count);
        error[count] = 0;
    }
    return -1;
}
} // namespace jsti_audio

namespace {
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
} // namespace

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
