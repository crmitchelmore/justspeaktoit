#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <mmdeviceapi.h>
#include <functiondiscoverykeys_devpkey.h>
#include <vector>

namespace {
struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
    // Enumeration may be called from an existing STA UI thread as well as a
    // Swift worker. Its existing apartment remains owned by the original caller.
    bool available() const { return SUCCEEDED(result) || result == RPC_E_CHANGED_MODE; }
};
struct DeviceID {
    LPWSTR value = nullptr;
    ~DeviceID() { if (value) CoTaskMemFree(value); }
};
struct Property {
    PROPVARIANT value{};
    ~Property() { PropVariantClear(&value); }
};
struct Device {
    std::string id;
    std::string name;
    bool isDefault = false;
};
}

int jsti_audio_devices_enumerate(JSTIAudioDeviceCallback callback, void *context,
                                 char *error, size_t errorCapacity) {
    if (!callback) return jsti::fail("No microphone list callback supplied.", error, errorCapacity);
    try {
        Apartment apartment;
        if (!apartment.available()) {
            return jsti::fail(jsti::systemError("Initializing microphone discovery", apartment.result), error, errorCapacity);
        }
        jsti::COM<IMMDeviceEnumerator> enumerator;
        HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator.value));
        if (FAILED(result)) return jsti::fail(jsti::systemError("Finding microphones", result), error, errorCapacity);
        jsti::COM<IMMDeviceCollection> collection;
        result = enumerator->EnumAudioEndpoints(eCapture, DEVICE_STATE_ACTIVE, &collection.value);
        if (FAILED(result)) return jsti::fail(jsti::systemError("Enumerating active microphones", result), error, errorCapacity);
        UINT count = 0;
        result = collection->GetCount(&count);
        if (FAILED(result)) return jsti::fail(jsti::systemError("Counting active microphones", result), error, errorCapacity);
        if (count > 4096) return jsti::fail("Windows returned an excessive number of microphones.", error, errorCapacity);
        if (!count) return 0;

        std::wstring defaultID;
        jsti::COM<IMMDevice> defaultDevice;
        result = enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications, &defaultDevice.value);
        if (SUCCEEDED(result)) {
            DeviceID identifier;
            result = defaultDevice->GetId(&identifier.value);
            if (FAILED(result) || !identifier.value) {
                return jsti::fail(jsti::systemError("Reading the default microphone ID", result), error, errorCapacity);
            }
            defaultID = identifier.value;
        } else if (result != HRESULT_FROM_WIN32(ERROR_NOT_FOUND)) {
            return jsti::fail(jsti::systemError("Finding the default communications microphone", result), error, errorCapacity);
        }

        std::vector<Device> devices;
        devices.reserve(count);
        for (UINT index = 0; index < count; ++index) {
            jsti::COM<IMMDevice> endpoint;
            result = collection->Item(index, &endpoint.value);
            if (FAILED(result)) return jsti::fail(jsti::systemError("Reading microphone endpoint", result), error, errorCapacity);
            DWORD state = 0;
            result = endpoint->GetState(&state);
            if (FAILED(result) || !(state & DEVICE_STATE_ACTIVE)) {
                return jsti::fail("The microphone list changed while loading. Refresh it before selecting a device.", error, errorCapacity);
            }
            DeviceID identifier;
            result = endpoint->GetId(&identifier.value);
            if (FAILED(result) || !identifier.value) {
                return jsti::fail(jsti::systemError("Reading microphone ID", result), error, errorCapacity);
            }
            jsti::COM<IPropertyStore> properties;
            result = endpoint->OpenPropertyStore(STGM_READ, &properties.value);
            if (FAILED(result)) return jsti::fail(jsti::systemError("Reading microphone properties", result), error, errorCapacity);
            Property name;
            result = properties->GetValue(PKEY_Device_FriendlyName, &name.value);
            if (FAILED(result) || name.value.vt != VT_LPWSTR || !name.value.pwszVal) {
                return jsti::fail("Windows did not provide a readable microphone name.", error, errorCapacity);
            }
            Device device;
            device.id = jsti::utf8(identifier.value);
            device.name = jsti::utf8(name.value.pwszVal);
            device.isDefault = !defaultID.empty() && defaultID == identifier.value;
            if (device.id.empty() || device.name.empty()) {
                return jsti::fail("Windows returned an invalid microphone name or identifier.", error, errorCapacity);
            }
            devices.push_back(std::move(device));
        }
        // A caller never receives a partial list followed by an enumeration
        // failure. Strings remain owned here until each synchronous callback ends.
        for (const auto &device : devices) {
            callback(device.id.c_str(), device.name.c_str(), device.isDefault ? 1 : 0, context);
        }
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Microphone discovery could not allocate or read its native resources.", error, errorCapacity);
    }
}

int jsti_audio_devices_self_test(char *error, size_t errorCapacity) {
    struct Callbacks { size_t audio = 0; size_t errors = 0; } callbacks;
    const auto audio = [](const int16_t *, size_t, void *context) { ++static_cast<Callbacks *>(context)->audio; };
    const auto failed = [](const char *, void *context) { ++static_cast<Callbacks *>(context)->errors; };
    char detail[1024]{};
    if (auto invalid = jsti_capture_create_with_device("\xff", audio, failed, &callbacks, detail, sizeof(detail))) {
        jsti_capture_destroy(invalid);
        return jsti::fail("An invalid UTF-8 microphone identifier was accepted.", error, errorCapacity);
    }
    if (!detail[0]) return jsti::fail("Invalid microphone identifier failure was not reported.", error, errorCapacity);
    detail[0] = 0;
    // Device IDs are opaque: production code never assumes their syntax. This
    // reserved synthetic ID cannot identify any Windows-generated endpoint.
    JSTICapture *missing = jsti_capture_create_with_device("jsti-self-test-missing-microphone-endpoint", audio, failed,
        &callbacks, detail, sizeof(detail));
    if (!missing) return jsti::fail("Could not create the missing-device test capture.", error, errorCapacity);
    const int started = jsti_capture_start(missing, detail, sizeof(detail));
    jsti_capture_destroy(missing);
    if (started != -1 || !detail[0] || callbacks.audio || callbacks.errors) {
        return jsti::fail("An unavailable explicit microphone did not fail synchronously without fallback.", error, errorCapacity);
    }
    return 0;
}
