#include "WindowsSupportInternal.hpp"
#include "include/CWindowsSupport.h"
#include <mmdeviceapi.h>
#include <atomic>
#include <memory>
#include <thread>
#include <vector>

namespace {
struct Device {
    std::string id, name;
    int isDefault = 0;
    bool operator==(const Device &other) const {
        return id == other.id && name == other.name && isDefault == other.isDefault;
    }
};
struct Signals {
    jsti::Handle wake;
    std::atomic<bool> stopping{false};
    std::atomic<bool> pending{true};
    Signals() { wake.value = CreateEventW(nullptr, FALSE, FALSE, nullptr); }
    void changed() noexcept {
        if (!stopping.load(std::memory_order_acquire)) {
            pending.store(true, std::memory_order_release);
            SetEvent(wake.value);
        }
    }
    void cancel() noexcept { stopping.store(true, std::memory_order_release); SetEvent(wake.value); }
};
class Notifications final : public IMMNotificationClient {
    std::atomic<ULONG> references{1};
    std::atomic<unsigned> callbacks{0};
    jsti::Handle drained;
    std::shared_ptr<Signals> signals;
    HRESULT changed(bool relevant = true) noexcept {
        if (callbacks.fetch_add(1, std::memory_order_acq_rel) == 0) ResetEvent(drained.value);
        if (relevant) signals->changed();
        if (callbacks.fetch_sub(1, std::memory_order_acq_rel) == 1) SetEvent(drained.value);
        return S_OK;
    }
public:
    explicit Notifications(std::shared_ptr<Signals> value) : signals(std::move(value)) {
        drained.value = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    }
    bool available() const { return drained.value != nullptr; }
    // Called only after unregistering/releasing the enumerator, never from an
    // IMMNotificationClient callback. Keep the registration reference throughout.
    void drain() { while (callbacks.load(std::memory_order_acquire)) WaitForSingleObject(drained.value, INFINITE); }
    ULONG STDMETHODCALLTYPE AddRef() override { return references.fetch_add(1) + 1; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = references.fetch_sub(1) - 1;
        if (!remaining) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
        if (!object) return E_POINTER;
        *object = nullptr;
        if (iid != __uuidof(IUnknown) && iid != __uuidof(IMMNotificationClient)) return E_NOINTERFACE;
        *object = static_cast<IMMNotificationClient *>(this); AddRef(); return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return changed(); }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return changed(); }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return changed(); }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override { return changed(); }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR) override {
        return changed(flow == eCapture && role == eCommunications);
    }
};
struct Backend {
    virtual ~Backend() = default;
    virtual bool start(Notifications *notifications, std::string &error) = 0;
    virtual bool stop(Notifications *notifications) noexcept = 0;
    virtual bool load(std::vector<Device> &devices, std::string &error) = 0;
};
struct WindowsBackend final : Backend {
    jsti::COM<IMMDeviceEnumerator> enumerator;
    bool registered = false;
    bool start(Notifications *notifications, std::string &error) override {
        HRESULT status = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
            __uuidof(IMMDeviceEnumerator), reinterpret_cast<void **>(&enumerator.value));
        if (SUCCEEDED(status)) status = enumerator->RegisterEndpointNotificationCallback(notifications);
        if (FAILED(status)) { error = jsti::systemError("Subscribing to microphone changes", status); return false; }
        registered = true;
        return true;
    }
    bool stop(Notifications *notifications) noexcept override {
        const HRESULT status = registered ? enumerator->UnregisterEndpointNotificationCallback(notifications) : S_OK;
        registered = false;
        if (FAILED(status) && status != E_NOTFOUND) {
            // An unexpected unregister failure cannot justify freeing a callback
            // still registered with Windows. Retain this inert native pair; its
            // signal is cancelled and it has no pointer to the Swift context.
            enumerator.value = nullptr;
            return false;
        }
        if (enumerator.value) { enumerator.value->Release(); enumerator.value = nullptr; }
        return true;
    }
    bool load(std::vector<Device> &devices, std::string &error) override {
        char message[1024]{};
        const auto found = [](const char *id, const char *name, int isDefault, void *context) {
            static_cast<std::vector<Device> *>(context)->push_back({id, name, isDefault});
        };
        if (jsti_audio_devices_enumerate(found, &devices, message, sizeof(message)) != 0) {
            devices.clear(); error = message; return false;
        }
        std::sort(devices.begin(), devices.end(), [](const Device &left, const Device &right) {
            return left.name == right.name ? left.id < right.id : left.name < right.name;
        });
        return true;
    }
};
struct MonitorState {
    std::shared_ptr<Signals> signals;
    std::shared_ptr<Backend> backend;
    JSTIAudioDevicesChangedCallback callback;
    void *context;
    bool apartment = true;
};
void run(const std::shared_ptr<MonitorState> &state) noexcept {
    const HRESULT initialized = state->apartment ? CoInitializeEx(nullptr, COINIT_MULTITHREADED) : S_OK;
    auto *notifications = new (std::nothrow) Notifications(state->signals);
    try {
        std::string error;
        const bool started = SUCCEEDED(initialized) && notifications && notifications->available() &&
            state->backend->start(notifications, error);
        if (!started) {
            if (error.empty()) error = "Microphone change monitoring could not initialize its native resources.";
            if (!state->signals->stopping.load()) state->callback(nullptr, 0, error.c_str(), state->context);
        } else {
            std::vector<Device> previous;
            std::string previousError;
            bool published = false;
            while (!state->signals->stopping.load(std::memory_order_acquire)) {
                if (!state->signals->pending.exchange(false, std::memory_order_acq_rel)) {
                    WaitForSingleObject(state->signals->wake.value, INFINITE);
                    continue;
                }
                std::vector<Device> devices;
                error.clear();
                if (!state->backend->load(devices, error) && error.empty()) error = "Could not refresh microphones.";
                if (state->signals->stopping.load(std::memory_order_acquire)) break;
                if (published && error == previousError && devices == previous) continue;
                std::vector<JSTIAudioDevice> snapshot;
                snapshot.reserve(devices.size());
                for (const auto &device : devices) snapshot.push_back({device.id.c_str(), device.name.c_str(), device.isDefault});
                state->callback(snapshot.data(), snapshot.size(), error.empty() ? nullptr : error.c_str(), state->context);
                previous = std::move(devices); previousError = error; published = true;
            }
        }
    } catch (...) {
        if (!state->signals->stopping.load()) {
            try { state->callback(nullptr, 0, "Microphone change monitoring stopped after a native error.", state->context); }
            catch (...) {}
        }
    }
    state->signals->cancel();
    // Microsoft requires unregister outside notification callbacks and manual
    // ownership of the notification object through the registration lifetime.
    if (notifications) {
        const bool unregistered = state->backend->stop(notifications);
        notifications->drain();
        if (unregistered) notifications->Release();
    }
    if (state->apartment && SUCCEEDED(initialized)) CoUninitialize();
}
}
struct JSTIAudioDeviceMonitor {
    std::shared_ptr<MonitorState> state;
    std::thread worker;
};
namespace {
JSTIAudioDeviceMonitor *create(JSTIAudioDevicesChangedCallback callback, void *context,
                              std::shared_ptr<Backend> backend, bool apartment, char *error, size_t capacity) {
    if (!callback) { jsti::fail("No microphone change callback supplied.", error, capacity); return nullptr; }
    try {
        auto monitor = std::make_unique<JSTIAudioDeviceMonitor>();
        auto state = std::make_shared<MonitorState>();
        state->signals = std::make_shared<Signals>();
        if (!state->signals->wake.value) { jsti::fail("Could not create microphone change signal.", error, capacity); return nullptr; }
        state->backend = std::move(backend); state->callback = callback; state->context = context; state->apartment = apartment;
        monitor->state = state;
        monitor->worker = std::thread([state] { run(state); });
        if (error && capacity) error[0] = 0;
        return monitor.release();
    } catch (...) { jsti::fail("Could not allocate microphone change monitoring.", error, capacity); return nullptr; }
}
}
JSTIAudioDeviceMonitor *jsti_audio_device_monitor_create(JSTIAudioDevicesChangedCallback callback, void *context,
                                                        char *error, size_t capacity) {
    try { return create(callback, context, std::make_shared<WindowsBackend>(), true, error, capacity); }
    catch (...) { jsti::fail("Could not allocate microphone change monitoring.", error, capacity); return nullptr; }
}
void jsti_audio_device_monitor_cancel(JSTIAudioDeviceMonitor *monitor) {
    if (monitor) monitor->state->signals->cancel();
}
int jsti_audio_device_monitor_destroy(JSTIAudioDeviceMonitor *monitor, char *error, size_t capacity) {
    if (!monitor) return 0;
    if (monitor->worker.get_id() == std::this_thread::get_id()) {
        return jsti::fail("The microphone snapshot callback cannot destroy its own worker.", error, capacity);
    }
    jsti_audio_device_monitor_cancel(monitor);
    if (monitor->worker.joinable()) monitor->worker.join();
    delete monitor;
    if (error && capacity) error[0] = 0;
    return 0;
}

namespace {
struct SyntheticBackend final : Backend {
    std::atomic<Notifications *> notifications{nullptr};
    std::atomic<int> version{0}, loads{0}, stops{0};
    std::atomic<bool> block{true};
    jsti::Handle entered, proceed;
    SyntheticBackend() {
        entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        proceed.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    }
    bool start(Notifications *value, std::string &) override { notifications = value; return true; }
    bool stop(Notifications *) noexcept override { notifications = nullptr; ++stops; return true; }
    bool load(std::vector<Device> &devices, std::string &) override {
        const int snapshot = version.load();
        ++loads;
        SetEvent(entered.value);
        if (block.load()) WaitForSingleObject(proceed.value, INFINITE);
        devices.push_back({"synthetic-" + std::to_string(snapshot), "Synthetic microphone", 1});
        return true;
    }
};
struct SyntheticSink {
    std::atomic<int> calls{0}, selfJoinStatus{99};
    std::atomic<JSTIAudioDeviceMonitor *> monitor{nullptr};
    jsti::Handle twice;
    SyntheticSink() { twice.value = CreateEventW(nullptr, TRUE, FALSE, nullptr); }
    static void changed(const JSTIAudioDevice *devices, size_t count, const char *error, void *context) {
        auto &sink = *static_cast<SyntheticSink *>(context);
        const int call = sink.calls.fetch_add(1);
        if (error || count != 1 || !devices || devices[0].is_default != 1 ||
            std::string(devices[0].id) != "synthetic-" + std::to_string(call)) {
            sink.calls = -100; SetEvent(sink.twice.value); return;
        }
        if (call == 0) {
            char message[128]{};
            sink.selfJoinStatus = jsti_audio_device_monitor_destroy(sink.monitor.load(), message, sizeof(message));
        }
        if (call == 1) SetEvent(sink.twice.value);
    }
};
struct SyntheticOwner {
    JSTIAudioDeviceMonitor *monitor = nullptr;
    std::shared_ptr<SyntheticBackend> backend;
    ~SyntheticOwner() {
        if (monitor) {
            jsti_audio_device_monitor_cancel(monitor);
            SetEvent(backend->proceed.value);
            jsti_audio_device_monitor_destroy(monitor, nullptr, 0);
        }
    }
};
}
int jsti_audio_device_monitor_self_test(char *error, size_t capacity) {
    try {
        auto backend = std::make_shared<SyntheticBackend>();
        SyntheticSink sink;
        if (!backend->entered.value || !backend->proceed.value || !sink.twice.value) {
            return jsti::fail("Could not allocate synthetic microphone monitor events.", error, capacity);
        }
        SyntheticOwner owner;
        owner.backend = backend;
        owner.monitor = create(SyntheticSink::changed, &sink, backend, false, error, capacity);
        if (!owner.monitor) return -1;
        sink.monitor = owner.monitor;
        if (WaitForSingleObject(backend->entered.value, 5000) != WAIT_OBJECT_0) {
            return jsti::fail("Synthetic microphone enumeration did not start.", error, capacity);
        }
        auto *notifications = backend->notifications.load();
        if (!notifications) return jsti::fail("Synthetic microphone subscription was missing.", error, capacity);
        // A burst during the first slow enumeration becomes exactly one more
        // snapshot, without losing the newer topology or making callback tasks.
        backend->version = 1;
        for (int index = 0; index < 10000; ++index) notifications->OnDeviceAdded(L"synthetic");
        SetEvent(backend->proceed.value);
        if (WaitForSingleObject(sink.twice.value, 5000) != WAIT_OBJECT_0 || sink.calls != 2 ||
            backend->loads != 2 || sink.selfJoinStatus != -1) {
            return jsti::fail("Microphone changes did not coalesce, retain newest state or reject callback self-join.", error, capacity);
        }
        // Render/default-role changes do not trigger a capture-device refresh.
        notifications->OnDefaultDeviceChanged(eRender, eCommunications, L"synthetic");
        notifications->OnDefaultDeviceChanged(eCapture, eConsole, L"synthetic");
        if (owner.monitor->state->signals->pending.load()) {
            return jsti::fail("Unrelated default roles scheduled microphone refreshes.", error, capacity);
        }
        // Cancel during an in-flight enumeration: it finishes privately but
        // never publishes into a context whose owner is shutting down.
        ResetEvent(backend->entered.value); ResetEvent(backend->proceed.value);
        backend->version = 2;
        notifications->OnDefaultDeviceChanged(eCapture, eCommunications, L"synthetic");
        if (WaitForSingleObject(backend->entered.value, 5000) != WAIT_OBJECT_0) {
            return jsti::fail("A changed communications microphone did not refresh.", error, capacity);
        }
        jsti_audio_device_monitor_cancel(owner.monitor);
        for (int index = 0; index < 1000; ++index) notifications->OnDeviceRemoved(L"synthetic");
        SetEvent(backend->proceed.value);
        if (jsti_audio_device_monitor_destroy(owner.monitor, error, capacity) != 0) return -1;
        owner.monitor = nullptr;
        if (sink.calls != 2 || backend->stops != 1 || backend->notifications.load()) {
            return jsti::fail("Microphone monitor shutdown published stale work or failed to unregister.", error, capacity);
        }
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (...) { return jsti::fail("Synthetic microphone monitoring checks failed.", error, capacity); }
}
