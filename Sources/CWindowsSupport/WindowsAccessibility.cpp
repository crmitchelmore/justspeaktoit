#include "WindowsSupportInternal.hpp"

#include <uiautomation.h>
#include <oleauto.h>

#include <set>

// Screen reader announcements and the automation-tree audit behind
// Docs/accessibility.md. Standard Win32 controls are exposed to UI Automation
// by the system proxy: a button's name is its text, a field's name is the
// static label just before it in tab order, and AutomationId is the control ID.
namespace jsti::accessibility {

void announce(HWND element, const std::wstring &text, bool important) {
    if (!element || text.empty() || !UiaClientsAreListening()) return;
    IRawElementProviderSimple *provider = nullptr;
    if (FAILED(UiaHostProviderFromHwnd(element, &provider)) || !provider) return;
    BSTR message = SysAllocString(text.c_str());
    BSTR activity = SysAllocString(L"JustSpeakToIt.State");
    if (message && activity) {
        UiaRaiseNotificationEvent(provider, NotificationKind_Other,
            important ? NotificationProcessing_ImportantMostRecent : NotificationProcessing_MostRecent,
            message, activity);
    }
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

// Fields take their name from the preceding shown static label.
static bool labelled(HWND control) {
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
