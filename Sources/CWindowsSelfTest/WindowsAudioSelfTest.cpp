// jsti_owned_capture_self_test and jsti_native_self_test: owned-capture receipts and
// retirement, PCM framing, the bounded ring and writer, and capture creation.
#include "CWindowsSelfTest.h"
#include "../CWindowsSupport/WindowsAudioCaptureInternal.hpp"

using namespace jsti_audio;

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
