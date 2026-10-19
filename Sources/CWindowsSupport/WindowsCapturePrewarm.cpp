#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mmdeviceapi.h>
#include <atomic>
#include <new>
#include <thread>

// Idle capture preparation. Mirrors the Mac's "prepare recording while idle":
// it resolves and validates the chosen endpoint and keeps the device
// enumerator and audio session library resident, but never activates an
// IAudioClient, so no stream is opened, no audio is read and the Windows
// microphone-in-use indicator stays off. The worker ends on destroy or when
// its bounded lifetime elapses, whichever comes first.
struct JSTICapturePrewarm {
    jsti::Handle stop;
    std::thread worker;
    std::atomic<int> state{0};
};

namespace {
struct PrewarmApartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~PrewarmApartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};

struct ResidentLibrary {
    HMODULE value = LoadLibraryExW(L"AudioSes.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    ~ResidentLibrary() { if (value) FreeLibrary(value); }
};

void prepare(JSTICapturePrewarm *prewarm, std::wstring identifier, DWORD lifetime) {
    PrewarmApartment apartment;
    ResidentLibrary library;
    jsti::COM<IMMDeviceEnumerator> enumerator;
    jsti::COM<IMMDevice> device;
    jsti::COM<IMMEndpoint> endpoint;
    bool ready = SUCCEEDED(apartment.result) && SUCCEEDED(CoCreateInstance(
        __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
        reinterpret_cast<void **>(&enumerator.value)));
    if (ready) {
        ready = SUCCEEDED(identifier.empty()
            ? enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications, &device.value)
            : enumerator->GetDevice(identifier.c_str(), &device.value));
    }
    DWORD deviceState = 0;
    if (ready) ready = SUCCEEDED(device->GetState(&deviceState)) && (deviceState & DEVICE_STATE_ACTIVE);
    EDataFlow flow = eAll;
    if (ready) {
        ready = SUCCEEDED(device->QueryInterface(__uuidof(IMMEndpoint), reinterpret_cast<void **>(&endpoint.value)))
            && SUCCEEDED(endpoint->GetDataFlow(&flow)) && flow == eCapture;
    }
    if (!ready) { prewarm->state.store(-1, std::memory_order_release); return; }
    prewarm->state.store(1, std::memory_order_release);
    WaitForSingleObject(prewarm->stop.value, lifetime);
    prewarm->state.store(2, std::memory_order_release);
}
}

JSTICapturePrewarm *jsti_capture_prewarm_create(const char *deviceID, uint32_t lifetimeMilliseconds,
                                                char *error, size_t errorCapacity) {
    std::wstring identifier;
    if (!jsti::wide(deviceID ? deviceID : "", identifier) || identifier.size() > 32767) {
        jsti::fail("The microphone identifier is not valid UTF-8 or is too long.", error, errorCapacity);
        return nullptr;
    }
    if (!lifetimeMilliseconds || lifetimeMilliseconds == INFINITE) {
        jsti::fail("Capture preparation needs a bounded lifetime.", error, errorCapacity);
        return nullptr;
    }
    std::unique_ptr<JSTICapturePrewarm> prewarm(new (std::nothrow) JSTICapturePrewarm());
    if (!prewarm) { jsti::fail("Could not allocate capture preparation.", error, errorCapacity); return nullptr; }
    prewarm->stop.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!prewarm->stop.value) {
        jsti::fail(jsti::systemError("Creating the capture preparation event"), error, errorCapacity);
        return nullptr;
    }
    try {
        prewarm->worker = std::thread(prepare, prewarm.get(), std::move(identifier), DWORD(lifetimeMilliseconds));
    } catch (...) {
        jsti::fail("Could not start capture preparation.", error, errorCapacity);
        return nullptr;
    }
    if (error && errorCapacity) error[0] = 0;
    return prewarm.release();
}

int jsti_capture_prewarm_state(JSTICapturePrewarm *prewarm) {
    return prewarm ? prewarm->state.load(std::memory_order_acquire) : -1;
}

void jsti_capture_prewarm_destroy(JSTICapturePrewarm *prewarm) {
    if (!prewarm) return;
    SetEvent(prewarm->stop.value);
    if (prewarm->worker.joinable()) prewarm->worker.join();
    delete prewarm;
}
