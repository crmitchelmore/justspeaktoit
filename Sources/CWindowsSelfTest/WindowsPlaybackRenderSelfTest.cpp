// Playback self-test: synthetic rendering: finish, acknowledgement, failures, pause, cancel, drain races and lifecycle.
#include "WindowsPlaybackSelfTestSupport.hpp"

namespace jsti::playback::selftest {

int selfTestSyntheticFinish(const std::wstring &fixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 1200, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    const auto before = run.snapshot();
    if (before.state != statePreparing || before.position_seconds != 0 || before.duration_seconds != -1) {
        return jsti::fail("A created playback did not report the preparing state.", error, capacity);
    }
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    char refused[256] = {};
    if (jsti_audio_playback_start(run.job, refused, sizeof(refused)) != -1 || !refused[0]) {
        return jsti::fail("Audio playback admitted a second start.", error, capacity);
    }
    if (!run.drive(240, deadline)) return jsti::fail("Synthetic playback did not complete.", error, capacity);
    const auto &engine = *run.engine;
    const auto after = run.snapshot();
    if (run.result.snapshot().callbacks != 1 || run.result.snapshot().status != 0 || !run.result.snapshot().error.empty() || !run.result.snapshot().selfDestroyRejected) {
        return jsti::fail("Synthetic playback did not finish with exactly one clean completion: " + run.result.snapshot().error, error, capacity);
    }
    if (!approximately(run.result.snapshot().played, 0.1) || after.state != stateEnded || !approximately(after.position_seconds, 0.1) ||
        !approximately(after.duration_seconds, 0.1)) {
        return jsti::fail("Finished playback did not report the full source position and duration.", error, capacity);
    }
    if (engine.submittedFrames != shortFrames || engine.consumedFrames != shortFrames || engine.queued != 0 ||
        engine.starts != 1 || engine.stops != 1 || engine.packets < 2 || engine.largestPacket > 1200 ||
        !matchesFixture(engine.heard.data(), engine.heard.size(), shortFrames)) {
        return jsti::fail("The engine heard padded, reordered or altered audio.", error, capacity);
    }
    if (jsti_audio_playback_pause(run.job) != 1 || jsti_audio_playback_resume(run.job) != 1) {
        return jsti::fail("Controls after the end of playback were not reported as ignored.", error, capacity);
    }
    if (!run.destroy(detail)) return jsti::fail(detail, error, capacity);
    if (!writable(fixture) || !verifyWaveFixture(fixture, shortFrames)) {
        return jsti::fail("Playback modified its source or kept it pinned after destroy.", error, capacity);
    }
    return 0;
}


struct SignalOnExit {
    HANDLE event;
    ~SignalOnExit() { if (event) SetEvent(event); }
};

// A 100 ms source fits inside a 500 ms output buffer. The production render
// loop must submit only its 2400 real frames and add no synthetic buffer tail.
// The synthetic clock charges only the device latency requested by that loop.
int selfTestShortSourceLargeBuffer(const std::wstring &fixture, char *error, size_t capacity) {
    for (DWORD latency : {DWORD{0}, DWORD{25}}) {
        SyntheticRun run;
        std::string detail;
        if (!run.create(fixture, pcm16Format(fixtureRate, 1), 12000, EngineOptions{}, detail)) {
            return jsti::fail(detail, error, capacity);
        }
        run.engine->latencyTicks = REFERENCE_TIME{latency} * 10000;
        if (!run.start(detail) || !run.drive(2400, deadline)) {
            return jsti::fail("The 100 ms source did not finish in its 500 ms engine buffer: " + detail, error, capacity);
        }
        const auto result = run.result.snapshot();
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        const auto &engine = *run.engine;
        if (result.status != 0 || engine.submittedFrames != shortFrames || engine.consumedFrames != shortFrames ||
            engine.packets != 1 || engine.largestPacket != shortFrames || engine.queued != 0 ||
            !matchesFixture(engine.heard.data(), engine.heard.size(), shortFrames) ||
            engine.requestedLatencyMilliseconds != latency || !approximately(result.played, 0.1)) {
            return jsti::fail("Short playback manufactured a tail or a delay beyond its modelled device latency.", error, capacity);
        }
        // Source duration 100 ms + the requested 0/25 ms device latency; no
        // 400 ms buffer-fill/drain overhead is charged to the synthetic clock.
    }
    return 0;
}

// Cancel versus a reserved Start: never acknowledge silence while Start can
// still return and make sound. A never-started cancellation is permanently quiet.
int selfTestOutputAcknowledgement(const std::wstring &fixture, char *error, size_t capacity) {
    jsti::Handle gate, entered;
    gate.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!gate.value || !entered.value) return jsti::fail("Could not create output acknowledgement gates.", error, capacity);
    SyntheticRun run;
    SignalOnExit unblock{gate.value};
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 12000, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    run.engine->startGate = gate.value;
    run.engine->startEntered = entered.value;
    if (!run.start(detail) || WaitForSingleObject(entered.value, deadline) != WAIT_OBJECT_0) {
        return jsti::fail("The synthetic Start was not reserved.", error, capacity);
    }
    jsti_audio_playback_cancel(run.job);
    if (run.snapshot().output_state != outputStarted) {
        return jsti::fail("Cancellation acknowledged quiet while a reserved Start was still in flight.", error, capacity);
    }
    SetEvent(gate.value);
    if (!run.result.wait(deadline) || run.snapshot().output_state != outputStopped) {
        return jsti::fail("The render thread did not acknowledge stopped output after cancellation.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        if (run.engine->started) return jsti::fail("Stopped output remained audible.", error, capacity);
    }
    if (!run.destroy(detail)) return jsti::fail(detail, error, capacity);
    SyntheticRun neverStarted;
    if (!neverStarted.create(fixture, pcm16Format(fixtureRate, 1), 12000, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    jsti_audio_playback_cancel(neverStarted.job);
    if (neverStarted.snapshot().output_state != outputNeverStarted || neverStarted.start(detail) ||
        neverStarted.result.wait(0) || neverStarted.engine->starts != 0) {
        return jsti::fail("A never-started quiet acknowledgement allowed a later native Start.", error, capacity);
    }
    return 0;
}

// Stall an actual MF source read after output begins, then fail the production
// render path. Witness awaitSample returning for the render result before the
// test releases the codec gate; a ready/read callback cannot mask the old 30 s bug.
int selfTestRenderFailureWakesReader(const std::wstring &fixture, bool stopFails, char *error, size_t capacity) {
    jsti::Handle gate, entered;
    gate.value = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!gate.value || !entered.value) return jsti::fail("Could not create the stalled decoder gates.", error, capacity);
    SyntheticRun run;
    SignalOnExit unblock{gate.value};
    EngineOptions options;
    options.readGate = gate.value;
    options.readGateEntered = entered.value;
    options.eventTimeout = 5000;
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 2400, options, detail)) return jsti::fail(detail, error, capacity);
    run.engine->closeReadGateOnStart = gate.value;
    const auto state = playbackReadState(run.job);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    bool stalled = false;
    const ULONGLONG until = GetTickCount64() + 5000;
    while (GetTickCount64() < until) {
        run.engine->consume(2400);
        if (WaitForSingleObject(entered.value, 0) == WAIT_OBJECT_0) {
            std::lock_guard<std::mutex> lock(state->mutex);
            stalled = state->pending && !state->ready;
        }
        if (stalled) break;
        Sleep(2);
    }
    if (!stalled) return jsti::fail("The actual decoder did not reach its gated pending read.", error, capacity);
    {
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        run.engine->paddingResult = AUDCLNT_E_DEVICE_INVALIDATED;
        if (stopFails) run.engine->stopResult = E_FAIL;
    }
    SetEvent(run.engine->event.value);
    {
        std::unique_lock<std::mutex> lock(state->mutex);
        if (!state->changed.wait_for(lock, std::chrono::seconds(2), [&] { return state->renderEndObserved; })) {
            return jsti::fail("Render failure did not wake the stalled pending read before codec release.", error, capacity);
        }
    }
    if (run.snapshot().output_state != (stopFails ? outputStarted : outputStopped)) {
        return jsti::fail(stopFails ? "A failed Stop falsely acknowledged quiet before endpoint release."
                                   : "Output was not acknowledged quiet before the stalled codec was released.", error, capacity);
    }
    SetEvent(gate.value); // Decoder teardown may now drain its native callback.
    if (!run.result.wait(5000)) return jsti::fail("The awakened render failure did not complete promptly.", error, capacity);
    const auto result = run.result.snapshot();
    if (result.status != -1 || result.error.find("disconnected") == std::string::npos || result.callbacks != 1) {
        return jsti::fail("The stalled-read wake lost the original render error: " + result.error, error, capacity);
    }
    if (run.snapshot().output_state != outputStopped) {
        return jsti::fail("Releasing the failed endpoint did not acknowledge quiet.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(run.engine->mutex);
        if (run.engine->started) return jsti::fail("Output survived release of its endpoint.", error, capacity);
    }
    return 0;
}

// Pause freezes the engine and the position; a pause longer than the event
// timeout is not a failure; resume continues from the same frames.
int selfTestSyntheticPauseResume(const std::wstring &longFixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    EngineOptions options;
    options.eventTimeout = 200;
    if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, options, detail)) return jsti::fail(detail, error, capacity);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    if (!run.waitForState(statePlaying, deadline)) return jsti::fail("Synthetic playback never started playing.", error, capacity);
    for (int step = 0; step < 6; ++step) { run.engine->consume(480); Sleep(5); }
    if (jsti_audio_playback_pause(run.job) != 0) return jsti::fail("Pause was not accepted while playing.", error, capacity);
    if (!run.engine->waitFor([&] { return run.engine->stops == 1 && !run.engine->started; }, deadline) ||
        !run.waitForState(statePaused, deadline)) {
        return jsti::fail("Pause did not stop the engine.", error, capacity);
    }
    const double pausedAt = run.snapshot().position_seconds;
    const uint64_t heardAtPause = run.engine->consumedFrames;
    if (pausedAt <= 0 || !approximately(pausedAt, static_cast<double>(heardAtPause) / fixtureRate)) {
        return jsti::fail("The paused position does not match the frames the engine consumed.", error, capacity);
    }
    Sleep(500); // Longer than the event timeout: a paused engine must not fail.
    if (run.engine->consume(480) != 0 || run.result.wait(0) || run.snapshot().state != statePaused ||
        run.snapshot().position_seconds != pausedAt || jsti_audio_playback_pause(run.job) != 0) {
        return jsti::fail("A paused playback advanced, consumed audio, failed or refused a repeated pause.", error, capacity);
    }
    if (jsti_audio_playback_resume(run.job) != 0 ||
        !run.engine->waitFor([&] { return run.engine->starts == 2 && run.engine->started; }, deadline) ||
        !run.waitForState(statePlaying, deadline)) {
        return jsti::fail("Resume did not restart the engine.", error, capacity);
    }
    double last = pausedAt;
    for (int step = 0; step < 4; ++step) {
        run.engine->consume(480);
        Sleep(5);
        const double position = run.snapshot().position_seconds;
        if (position < last) return jsti::fail("The position moved backwards after resume.", error, capacity);
        last = position;
    }
    if (!run.drive(480, deadline)) return jsti::fail("Resumed playback did not complete.", error, capacity);
    if (run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 2.0) || run.engine->consumedFrames != longFrames ||
        !matchesFixture(run.engine->heard.data(), run.engine->heard.size(), longFrames)) {
        return jsti::fail("Playback across a pause lost, duplicated or altered audio: " + run.result.snapshot().error, error, capacity);
    }
    return 0;
}

int selfTestSyntheticCancelWhilePaused(const std::wstring &longFixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    if (!run.waitForState(statePlaying, deadline)) return jsti::fail("Playback never started before the pause.", error, capacity);
    for (int step = 0; step < 4; ++step) { run.engine->consume(480); Sleep(5); }
    jsti_audio_playback_pause(run.job);
    if (!run.waitForState(statePaused, deadline)) return jsti::fail("Pause was not acknowledged.", error, capacity);
    const double pausedAt = run.snapshot().position_seconds;
    jsti_audio_playback_cancel(run.job);
    if (!run.result.wait(deadline)) return jsti::fail("Cancelling a paused playback did not complete.", error, capacity);
    if (run.result.snapshot().status != 1 || run.result.snapshot().callbacks != 1 || !approximately(run.result.snapshot().played, pausedAt) ||
        run.engine->consumedFrames != static_cast<uint64_t>(pausedAt * fixtureRate + 0.5) ||
        run.snapshot().state != stateEnded) {
        return jsti::fail("Cancelling while paused misreported the heard position.", error, capacity);
    }
    return 0;
}

// End of stream races: the whole file is queued before the engine starts, so
// pausing and cancelling happen while the engine drains its buffer. Only the
// frames the engine consumed count as heard.
int selfTestSyntheticDrainRaces(const std::wstring &fixture, char *error, size_t capacity) {
    {
        SyntheticRun run;
        std::string detail;
        if (!run.create(fixture, pcm16Format(fixtureRate, 1), 4800, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.engine->waitFor([&] { return run.engine->submittedFrames == shortFrames && run.engine->started; }, deadline)) {
            return jsti::fail("The short file was not pre-rolled in full before the engine started.", error, capacity);
        }
        run.engine->consume(1000);
        jsti_audio_playback_pause(run.job);
        if (!run.waitForState(statePaused, deadline) || !approximately(run.snapshot().position_seconds, 1000.0 / fixtureRate)) {
            return jsti::fail("Pausing during the drain misreported the position.", error, capacity);
        }
        jsti_audio_playback_resume(run.job);
        if (!run.waitForState(statePlaying, deadline) || !run.drive(480, deadline)) {
            return jsti::fail("Resuming during the drain did not finish playback.", error, capacity);
        }
        if (run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 0.1) || run.engine->consumedFrames != shortFrames) {
            return jsti::fail("A drain interrupted by pause lost audio.", error, capacity);
        }
    }
    {
        SyntheticRun run;
        std::string detail;
        if (!run.create(fixture, pcm16Format(fixtureRate, 1), 4800, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.engine->waitFor([&] { return run.engine->submittedFrames == shortFrames && run.engine->started; }, deadline)) {
            return jsti::fail("The short file was not pre-rolled before cancellation.", error, capacity);
        }
        run.engine->consume(1000);
        run.engine->waitFor([&] { return false; }, 30); // Let the engine observe the consumption.
        jsti_audio_playback_cancel(run.job);
        if (!run.result.wait(deadline)) return jsti::fail("Cancelling during the drain did not complete.", error, capacity);
        // 2400 frames were queued and 1000 heard: the counterexample from the
        // review must report exactly 1000 heard frames, not the queued total.
        if (run.result.snapshot().status != 1 || !approximately(run.result.snapshot().played, 1000.0 / fixtureRate) || run.engine->consumedFrames != 1000) {
            return jsti::fail("Cancelling during the drain counted queued frames as heard.", error, capacity);
        }
    }
    return 0;
}

int selfTestSyntheticFailures(const std::wstring &longFixture, char *error, size_t capacity) {
    {
        SyntheticRun run;
        std::string detail;
        EngineOptions options;
        options.eventTimeout = 200;
        if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, options, detail)) return jsti::fail(detail, error, capacity);
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.waitForState(statePlaying, deadline)) return jsti::fail("Playback never started before the silent engine check.", error, capacity);
        // The engine never asks for audio again: a started stream that stops
        // signalling is an explicit failure, never a hang.
        if (!run.result.wait(deadline) || run.result.snapshot().status != -1 ||
            run.result.snapshot().error.find("stopped requesting audio") == std::string::npos || run.snapshot().state != stateEnded) {
            return jsti::fail("A silent engine did not fail with the event timeout: " + run.result.snapshot().error, error, capacity);
        }
    }
    {
        SyntheticRun run;
        std::string detail;
        if (!run.create(longFixture, pcm16Format(fixtureRate, 1), 2400, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
        run.engine->startResult = AUDCLNT_E_DEVICE_INVALIDATED;
        if (!run.start(detail)) return jsti::fail(detail, error, capacity);
        if (!run.result.wait(deadline) || run.result.snapshot().status != -1 || run.result.snapshot().played != 0 ||
            run.result.snapshot().error.find("disconnected") == std::string::npos) {
            return jsti::fail("A device failure at start was not reported: " + run.result.snapshot().error, error, capacity);
        }
    }
    return 0;
}

int selfTestSyntheticPauseBeforeStart(const std::wstring &fixture, char *error, size_t capacity) {
    SyntheticRun run;
    std::string detail;
    if (!run.create(fixture, pcm16Format(fixtureRate, 1), 1200, EngineOptions{}, detail)) return jsti::fail(detail, error, capacity);
    if (jsti_audio_playback_pause(run.job) != 0) return jsti::fail("Pause before start was refused.", error, capacity);
    if (!run.start(detail)) return jsti::fail(detail, error, capacity);
    if (!run.waitForState(statePaused, deadline) || run.engine->starts != 0 || run.snapshot().position_seconds != 0 ||
        run.engine->submittedFrames == 0) {
        return jsti::fail("A pause requested before start did not hold the pre-rolled engine.", error, capacity);
    }
    jsti_audio_playback_resume(run.job);
    if (!run.drive(240, deadline) || run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 0.1) || run.engine->starts != 1) {
        return jsti::fail("Resuming a playback paused before start did not play it out.", error, capacity);
    }
    return 0;
}

int selfTestLifecycle(const std::wstring &fixture, const std::wstring &tinyFixture, char *error, size_t capacity) {
    char detail[1024] = {};
    const std::string input = jsti::utf8(fixture);
    auto unexpected = [](int, double, const char *, void *context) { *static_cast<bool *>(context) = true; };
    bool called = false;
    if (jsti_audio_playback_create(input.c_str(), nullptr, &called, detail, sizeof(detail)) || !detail[0]) {
        return jsti::fail("Audio playback accepted a missing callback.", error, capacity);
    }
    const char *invalid[] = {"relative.wav", "", "C:\\", "C:\\folder\\..\\audio.wav", "\xc3\x28"};
    for (const char *path : invalid) {
        detail[0] = 0;
        if (jsti_audio_playback_create(path, unexpected, &called, detail, sizeof(detail)) || !detail[0]) {
            return jsti::fail("Audio playback accepted an unsafe input path.", error, capacity);
        }
    }
    detail[0] = 0;
    if (jsti_audio_playback_create((input + ".missing").c_str(), unexpected, &called, detail, sizeof(detail)) || !detail[0]) {
        return jsti::fail("Audio playback accepted a missing input file.", error, capacity);
    }
    JSTIAudioPlaybackSnapshot snapshot{};
    if (jsti_audio_playback_snapshot(nullptr, &snapshot) != -1 || jsti_audio_playback_pause(nullptr) != -1 ||
        jsti_audio_playback_resume(nullptr) != -1 || jsti_audio_playback_destroy(nullptr, detail, sizeof(detail)) != 0) {
        return jsti::fail("Null playback handles were not rejected consistently.", error, capacity);
    }
    // Cancelled before start: refused synchronously, no callback, clean destroy,
    // and the pin is released without the file ever being read by a codec.
    std::memcpy(detail, "stale", 6);
    auto *cancelled = jsti_audio_playback_create(input.c_str(), unexpected, &called, detail, sizeof(detail));
    if (!cancelled || detail[0]) return jsti::fail("Audio playback creation failed or left a stale error.", error, capacity);
    if (writable(fixture)) return jsti::fail("A created playback did not pin its source.", error, capacity);
    jsti_audio_playback_cancel(cancelled);
    const int start = jsti_audio_playback_start(cancelled, detail, sizeof(detail));
    const int destroyed = jsti_audio_playback_destroy(cancelled, detail, sizeof(detail));
    if (start != -1 || destroyed != 0 || called || !writable(fixture)) {
        return jsti::fail("Cancelled-before-start audio playback ran, invoked its callback or kept its pin.", error, capacity);
    }
    // A 10 ms file completes about as fast as start returns; the completion
    // still arrives exactly once and destroy still joins cleanly.
    for (int attempt = 0; attempt < 3; ++attempt) {
        SyntheticRun run;
        std::string failure;
        if (!run.create(tinyFixture, pcm16Format(fixtureRate, 1), 480, EngineOptions{}, failure)) return jsti::fail(failure, error, capacity);
        if (!run.start(failure)) return jsti::fail(failure, error, capacity);
        if (!run.drive(240, deadline) || run.result.snapshot().callbacks != 1 || run.result.snapshot().status != 0 || !approximately(run.result.snapshot().played, 0.01) ||
            !run.result.snapshot().selfDestroyRejected) {
            return jsti::fail("An immediately completing playback broke the exactly-once contract.", error, capacity);
        }
        if (!run.destroy(failure)) return jsti::fail(failure, error, capacity);
        if (run.result.snapshot().callbacks != 1) return jsti::fail("A completion arrived after destroy.", error, capacity);
    }
    return 0;
}

} // namespace jsti::playback::selftest
