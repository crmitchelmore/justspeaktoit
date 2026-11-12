#include "WindowsSupportInternal.hpp"

#include <commctrl.h>
#include <ole2.h>
#include <oleacc.h>
#include <uiautomation.h>

#include <set>

// Screen reader announcements and the automation-tree audit behind
// Docs/accessibility.md. Standard Win32 controls are exposed to UI Automation
// by the system proxy: a button's name is its text, a field's name is the
// static label just before it in tab order, and AutomationId is the control ID.
namespace jsti::accessibility {

// UiaRaiseNotificationEvent (Windows 10 1709) is resolved at run time, so the
// SDK's version guards and older systems cannot break the build or the launch.
using RaiseNotification = HRESULT(WINAPI *)(IRawElementProviderSimple *, int, int, BSTR, BSTR);
constexpr int notificationKindOther = 4;
constexpr int processingImportantMostRecent = 1, processingMostRecent = 3;

static RaiseNotification raiseNotification() {
    static const RaiseNotification function = [] {
        HMODULE module = GetModuleHandleW(L"UIAutomationCore.dll");
        if (!module) module = LoadLibraryExW(L"UIAutomationCore.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return module ? reinterpret_cast<RaiseNotification>(
            reinterpret_cast<void *>(GetProcAddress(module, "UiaRaiseNotificationEvent"))) : nullptr;
    }();
    return function;
}

// UI Automation drops notifications raised on the bare provider from
// UiaHostProviderFromHwnd: no client hears them. They are delivered when the
// top-level window answers WM_GETOBJECT/UiaRootObjectId with its own
// server-side provider and the event comes from that provider. The provider
// adds no properties, so the window keeps the system proxy's name and role.
namespace {
constexpr wchar_t providerProperty[] = L"JustSpeakToIt.AnnouncementProvider";
constexpr UINT_PTR providerSubclass = 0x4A53;

class RootProvider final : public IRawElementProviderSimple {
public:
    explicit RootProvider(HWND window) : window(window) {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {
        if (!object) return E_POINTER;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *object = static_cast<IRawElementProviderSimple *>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&references)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG remaining = InterlockedDecrement(&references);
        if (remaining == 0) delete this;
        return static_cast<ULONG>(remaining);
    }
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *options) override {
        if (!options) return E_POINTER;
        *options = ProviderOptions_ServerSideProvider;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID, IUnknown **pattern) override {
        if (!pattern) return E_POINTER;
        *pattern = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID, VARIANT *value) override {
        if (!value) return E_POINTER;
        value->vt = VT_EMPTY;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **host) override {
        if (!host) return E_POINTER;
        *host = nullptr;
        return IsWindow(window) ? UiaHostProviderFromHwnd(window, host) : UIA_E_ELEMENTNOTAVAILABLE;
    }

private:
    ~RootProvider() = default;
    HWND window;
    LONG references = 1;
};

LRESULT CALLBACK serveProvider(HWND window, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR data) {
    auto *provider = reinterpret_cast<RootProvider *>(data);
    if (message == WM_GETOBJECT && static_cast<LONG>(lparam) == UiaRootObjectId)
        return UiaReturnRawElementProvider(window, wparam, lparam, provider);
    if (message == WM_NCDESTROY) {
        UiaReturnRawElementProvider(window, 0, 0, nullptr);
        RemovePropW(window, providerProperty);
        RemoveWindowSubclass(window, serveProvider, providerSubclass);
        const LRESULT result = DefSubclassProc(window, message, wparam, lparam);
        provider->Release();
        return result;
    }
    return DefSubclassProc(window, message, wparam, lparam);
}

RootProvider *rootProvider(HWND window) {
    return static_cast<RootProvider *>(GetPropW(window, providerProperty));
}
} // namespace

void attach(HWND window) {
    if (!window || GetAncestor(window, GA_ROOT) != window || rootProvider(window) ||
        GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) return;
    auto *provider = new RootProvider(window);
    if (!SetWindowSubclass(window, serveProvider, providerSubclass, reinterpret_cast<DWORD_PTR>(provider)) ||
        !SetPropW(window, providerProperty, provider)) {
        RemoveWindowSubclass(window, serveProvider, providerSubclass);
        provider->Release();
    }
}

bool attached(HWND window) { return window && rootProvider(window) != nullptr; }

namespace {
constexpr wchar_t nameProperty[] = L"JustSpeakToIt.AccessibleName";
// PROPID_ACC_NAME, spelled out so no translation unit has to define oleacc's GUIDs.
constexpr GUID accessibleNameProperty = {0x608d3df8, 0x8128, 0x4aa7, {0xa4, 0x28, 0xf5, 0x5e, 0x49, 0x26, 0x72, 0x91}};
} // namespace

bool name(HWND control, const wchar_t *text) {
    if (!control || !text || !*text) return false;
    const HRESULT apartment = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IAccPropServices *services = nullptr;
    HRESULT result = CoCreateInstance(__uuidof(CAccPropServices), nullptr, CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&services));
    if (SUCCEEDED(result)) {
        result = services->SetHwndPropStr(control, OBJID_CLIENT, CHILDID_SELF, accessibleNameProperty, text);
        services->Release();
    }
    if (SUCCEEDED(apartment)) CoUninitialize();
    if (FAILED(result)) return false;
    SetPropW(control, nameProperty, reinterpret_cast<HANDLE>(1));
    return true;
}

void announce(HWND element, const std::wstring &text, bool important) {
    const RaiseNotification raise = raiseNotification();
    if (!raise || !element || text.empty() || !UiaClientsAreListening()) return;
    const HWND root = GetAncestor(element, GA_ROOT);
    attach(root);
    IRawElementProviderSimple *provider = rootProvider(root);
    if (provider) provider->AddRef();
    else if (FAILED(UiaHostProviderFromHwnd(element, &provider)) || !provider) return;
    BSTR message = SysAllocString(text.c_str());
    BSTR activity = SysAllocString(L"JustSpeakToIt.State");
    if (message && activity)
        raise(provider, notificationKindOther, important ? processingImportantMostRecent : processingMostRecent,
              message, activity);
    SysFreeString(message);
    SysFreeString(activity);
    provider->Release();
}

static std::string className(HWND window) {
    char name[64]{};
    GetClassNameA(window, name, 64);
    return name;
}

static bool shown(HWND window) {
    return (GetWindowLongPtrW(window, GWL_STYLE) & WS_VISIBLE) != 0;
}

// Fields take their name from the preceding shown static label, or from name().
static bool labelled(HWND control) {
    if (GetPropW(control, nameProperty)) return true;
    HWND previous = GetWindow(control, GW_HWNDPREV);
    while (previous && !shown(previous)) previous = GetWindow(previous, GW_HWNDPREV);
    return previous && _stricmp(className(previous).c_str(), "Static") == 0 &&
        GetWindowTextLengthW(previous) > 0;
}

// Uses style bits rather than IsWindowVisible so a hidden smoke-test window is still audited.
int audit(HWND root, std::string &failure) {
    std::set<int> seen;
    int checked = 0;
    for (HWND child = GetWindow(root, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT)) {
        if (!shown(child) || !(GetWindowLongPtrW(child, GWL_STYLE) & WS_TABSTOP)) continue;
        const int id = GetDlgCtrlID(child);
        const std::string control = className(child) + " #" + std::to_string(id);
        if (id == 0 || !seen.insert(id).second) {
            failure = "Accessibility audit: focusable " + control + " has no unique AutomationId.";
            return -1;
        }
        const bool button = _stricmp(className(child).c_str(), "Button") == 0;
        if (button ? GetWindowTextLengthW(child) == 0 : !labelled(child)) {
            failure = "Accessibility audit: focusable " + control + " has no accessible name.";
            return -1;
        }
        ++checked;
    }
    return checked;
}

} // namespace jsti::accessibility
