#include "WindowsPlaybackSelfTestSupport.hpp"

// Synthetic checks for the playback engine. A synthetic output engine stands
// in for WASAPI so the production decode/queue/render code runs on machines
// without a speaker; the physical endpoint acceptance lives in the Swift tests
// behind the explicit capability probe.

using namespace jsti::playback::selftest;

int jsti_audio_playback_self_test(char *error, size_t capacity) {
    try {
        if (selfTestRing(error, capacity) || selfTestStalledDecodeCancel(error, capacity)) return -1;
        wchar_t temporary[32768] = {};
        const DWORD count = GetTempPathW(static_cast<DWORD>(std::size(temporary)), temporary);
        GUID guid{};
        wchar_t identifier[40] = {};
        if (!count || count >= std::size(temporary) || FAILED(CoCreateGuid(&guid)) ||
            !StringFromGUID2(guid, identifier, static_cast<int>(std::size(identifier)))) {
            return jsti::fail("Could not create unique playback test paths.", error, capacity);
        }
        const std::wstring root = std::wstring(temporary) + L"JustSpeakToIt-playback-test-" + identifier;
        if (!absent(root)) return jsti::fail("Playback test path already exists.", error, capacity);
        char detail[1024] = {};
        if (jsti_private_directory_prepare(jsti::utf8(root).c_str(), detail, sizeof(detail)) != 0) {
            return jsti::fail(detail, error, capacity);
        }
        PlaybackTestFiles files;
        files.root = root;
        const auto fixture = files.path(L"tone-24khz.wav");
        const auto longFixture = files.path(L"tone-2s-24khz.wav");
        const auto tinyFixture = files.path(L"tone-10ms-24khz.wav");
        const auto stalledFixture = files.path(L"tone-stalled-30s-24khz.wav");
        const auto corrupt = files.path(L"corrupt.wav");
        createWaveFixture(fixture, fixtureRate, 1, shortFrames);
        createWaveFixture(longFixture, fixtureRate, 1, longFrames);
        createWaveFixture(tinyFixture, fixtureRate, 1, 240);
        createWaveFixture(stalledFixture, fixtureRate, 1, fixtureRate * 30);
        {
            std::string failure;
            jsti::Handle file;
            file.value = jsti::createPrivateFileHandle(jsti::utf8(corrupt).c_str(), failure);
            if (file.value == INVALID_HANDLE_VALUE) { file.value = nullptr; return jsti::fail(failure, error, capacity); }
            const uint8_t junk[] = {1, 2, 3, 4, 5, 6};
            writeBytes(file.value, junk, sizeof(junk));
        }
        if (selfTestSourceValidation(fixture, root, error, capacity) ||
            selfTestDecoder(fixture, longFixture, corrupt, error, capacity) ||
            selfTestSyntheticFinish(fixture, error, capacity) ||
            selfTestShortSourceLargeBuffer(fixture, error, capacity) ||
            selfTestOutputAcknowledgement(fixture, error, capacity) ||
            selfTestRenderFailureWakesReader(stalledFixture, false, error, capacity) ||
            selfTestRenderFailureWakesReader(stalledFixture, true, error, capacity) ||
            selfTestSyntheticPauseResume(longFixture, error, capacity) ||
            selfTestSyntheticCancelWhilePaused(longFixture, error, capacity) ||
            selfTestSyntheticDrainRaces(fixture, error, capacity) ||
            selfTestSyntheticFailures(longFixture, error, capacity) ||
            selfTestSyntheticPauseBeforeStart(fixture, error, capacity) ||
            selfTestLifecycle(fixture, tinyFixture, error, capacity)) return -1;
        if (!verifyWaveFixture(fixture, shortFrames) || !verifyWaveFixture(longFixture, longFrames)) {
            return jsti::fail("A playback self-test modified its synthetic source.", error, capacity);
        }
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const Failure &failure) {
        return jsti::fail(describe(failure), error, capacity);
    } catch (const Cancelled &) {
        return jsti::fail("Audio playback self-test was cancelled unexpectedly.", error, capacity);
    } catch (const std::exception &) {
        return jsti::fail("Audio playback self-test could not allocate its state.", error, capacity);
    }
}
