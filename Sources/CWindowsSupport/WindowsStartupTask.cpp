#include "WindowsLoginItem.hpp"

#include <roapi.h>
#include <winstring.h>
#include <windows.applicationmodel.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <thread>

// The MSIX app's windows.startupTask through the WinRT StartupTask API. The
// WinRT entry points come from combase.dll at run time, so the portable
// bundle, which never calls this, imports nothing new.
namespace jsti::login::task {
namespace {

namespace model = ABI::Windows::ApplicationModel;
namespace foundation = ABI::Windows::Foundation;
using Microsoft::WRL::ComPtr;

// Enabling may ask the shell, which answers within a second or two.
constexpr ULONGLONG timeoutMilliseconds = 10000;

struct Runtime {
    HMODULE module = nullptr;
    decltype(&RoInitialize) initialize = nullptr;
    decltype(&RoUninitialize) uninitialize = nullptr;
    decltype(&RoGetActivationFactory) factory = nullptr;
    decltype(&WindowsCreateStringReference) reference = nullptr;

    Runtime() {
        module = LoadLibraryExW(L"combase.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) return;
        load(initialize, "RoInitialize");
        load(uninitialize, "RoUninitialize");
        load(factory, "RoGetActivationFactory");
        load(reference, "WindowsCreateStringReference");
    }
    template<class Function> void load(Function &function, const char *name) {
        const FARPROC address = GetProcAddress(module, name);
        static_assert(sizeof(function) == sizeof(address), "Windows function pointer size");
        std::memcpy(&function, &address, sizeof(function));
    }
    ~Runtime() { if (module) FreeLibrary(module); }
    bool loaded() const { return initialize && uninitialize && factory && reference; }
};

std::string hresultError(const char *operation, HRESULT result) {
    char code[16];
    std::snprintf(code, sizeof code, "0x%08lX", static_cast<unsigned long>(result));
    return std::string(operation) + " failed (" + code + ").";
}

// Polls, so no completion handler object is needed; the wait is bounded.
HRESULT wait(IUnknown *operation) {
    ComPtr<foundation::IAsyncInfo> info;
    HRESULT result = operation->QueryInterface(IID_PPV_ARGS(&info));
    if (FAILED(result)) return result;
    const ULONGLONG deadline = GetTickCount64() + timeoutMilliseconds;
    foundation::AsyncStatus status = foundation::AsyncStatus::Started;
    while (SUCCEEDED(result = info->get_Status(&status)) && status == foundation::AsyncStatus::Started) {
        if (GetTickCount64() >= deadline) {
            info->Cancel();
            return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        }
        Sleep(10);
    }
    if (FAILED(result)) return result;
    if (status == foundation::AsyncStatus::Completed) return S_OK;
    HRESULT code = E_FAIL;
    info->get_ErrorCode(&code);
    return FAILED(code) ? code : E_ABORT;
}

State translate(model::StartupTaskState value) {
    switch (static_cast<int>(value)) {
    case 0: return off;          // Disabled
    case 2: return on;           // Enabled
    case 1: case 3: return offBySystem; // DisabledByUser, DisabledByPolicy
    case 4: return onBySystem;   // EnabledByPolicy
    default: return unavailable;
    }
}

// One request, on a thread of its own in the multithreaded apartment, so
// neither the caller's apartment nor the UI thread's message loop matters.
bool request(bool change, bool enabled, State &reached, std::string &failure) {
    Runtime runtime;
    if (!runtime.loaded()) {
        failure = "Launch at login needs the Windows Runtime (combase.dll).";
        return false;
    }
    std::thread worker([&] {
        HRESULT result = runtime.initialize(RO_INIT_MULTITHREADED);
        const bool initialized = SUCCEEDED(result);
        if (FAILED(result) && result != RPC_E_CHANGED_MODE) {
            failure = hresultError("Starting the Windows Runtime", result);
            return;
        }
        [&] {
            HSTRING_HEADER classHeader{}, idHeader{};
            HSTRING className = nullptr, id = nullptr;
            const UINT32 classLength = static_cast<UINT32>(wcslen(RuntimeClass_Windows_ApplicationModel_StartupTask));
            result = runtime.reference(RuntimeClass_Windows_ApplicationModel_StartupTask, classLength, &classHeader,
                                       &className);
            if (SUCCEEDED(result)) result = runtime.reference(identifier, static_cast<UINT32>(wcslen(identifier)),
                                                              &idHeader, &id);
            ComPtr<model::IStartupTaskStatics> statics;
            if (SUCCEEDED(result)) result = runtime.factory(className, IID_PPV_ARGS(&statics));
            if (FAILED(result)) { failure = hresultError("Opening the startup task API", result); return; }
            ComPtr<__FIAsyncOperation_1_Windows__CApplicationModel__CStartupTask> lookup;
            result = statics->GetAsync(id, &lookup);
            if (SUCCEEDED(result)) result = wait(lookup.Get());
            ComPtr<model::IStartupTask> startup;
            if (SUCCEEDED(result)) result = lookup->GetResults(&startup);
            if (FAILED(result)) { failure = hresultError("Finding the app's startup task", result); return; }
            model::StartupTaskState value{};
            if (change && enabled) {
                ComPtr<__FIAsyncOperation_1_Windows__CApplicationModel__CStartupTaskState> enabling;
                result = startup->RequestEnableAsync(&enabling);
                if (SUCCEEDED(result)) result = wait(enabling.Get());
                if (SUCCEEDED(result)) result = enabling->GetResults(&value);
                if (FAILED(result)) { failure = hresultError("Turning on the startup task", result); return; }
                reached = translate(value);
                return;
            }
            if (change) {
                // Disable refuses nothing: a task the user or a policy turned
                // off stays off, and one a policy keeps on reports so below.
                result = startup->Disable();
                if (FAILED(result)) { failure = hresultError("Turning off the startup task", result); return; }
            }
            result = startup->get_State(&value);
            if (FAILED(result)) { failure = hresultError("Reading the startup task", result); return; }
            reached = translate(value);
        }();
        if (initialized) runtime.uninitialize();
    });
    worker.join();
    return failure.empty();
}

} // namespace

bool state(State &current, std::string &failure) { return request(false, false, current, failure); }

bool set(bool enabled, State &reached, std::string &failure) { return request(true, enabled, reached, failure); }

} // namespace jsti::login::task
