#include "include/CWindowsSupport.h"
#include "WindowsLoginItem.hpp"

#include <appmodel.h>
#include <shellapi.h>

#include <vector>

namespace jsti::login {
namespace {

constexpr wchar_t runKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t approvedKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run";

std::wstring executablePath() {
    std::vector<wchar_t> path(MAX_PATH);
    for (;;) {
        const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
        if (length == 0) return {};
        if (length < path.size()) return std::wstring(path.data(), length);
        if (path.size() >= 32768) return {};
        path.resize(path.size() * 2);
    }
}

bool present(LSTATUS status) { return status == ERROR_SUCCESS; }
bool absent(LSTATUS status) { return status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND; }

// Task Manager and Settings › Apps › Startup record their switch here: an odd
// first byte is off, an even one (or no entry) leaves the Run value on.
bool approvedOff(const wchar_t *name) {
    BYTE data[16] = {};
    DWORD size = sizeof data;
    const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, approvedKey, name, RRF_RT_REG_BINARY, nullptr, data, &size);
    return present(status) && size > 0 && (data[0] & 1) != 0;
}

} // namespace

bool launchedAtLogin() {
    int count = 0;
    LPWSTR *arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!arguments) return false;
    bool found = false;
    for (int index = 1; index < count && !found; ++index) found = lstrcmpW(arguments[index], launchArgument) == 0;
    LocalFree(arguments);
    return found;
}

bool packaged() {
    UINT32 length = 0;
    return GetCurrentPackageFullName(&length, nullptr) == ERROR_INSUFFICIENT_BUFFER;
}

State registryState(const wchar_t *name) {
    DWORD size = 0;
    const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, runKey, name, RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ |
                                        RRF_NOEXPAND, nullptr, nullptr, &size);
    if (!present(status)) return off;
    return approvedOff(name) ? off : on;
}

bool setRegistry(const wchar_t *name, const std::wstring &command, bool enabled, std::string &failure) {
    if (enabled) {
        HKEY key = nullptr;
        LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, runKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                                         nullptr);
        if (!present(status)) { failure = systemError("Opening the Run key", status); return false; }
        const DWORD bytes = static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
        status = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE *>(command.c_str()), bytes);
        RegCloseKey(key);
        if (!present(status)) { failure = systemError("Registering the login item", status); return false; }
    } else {
        const LSTATUS status = RegDeleteKeyValueW(HKEY_CURRENT_USER, runKey, name);
        if (!present(status) && !absent(status)) {
            failure = systemError("Removing the login item", status);
            return false;
        }
    }
    // The user's choice now: an old Task Manager "Disabled" must not outlive it.
    const LSTATUS approved = RegDeleteKeyValueW(HKEY_CURRENT_USER, approvedKey, name);
    if (!present(approved) && !absent(approved)) {
        failure = systemError("Clearing the startup approval", approved);
        return false;
    }
    return true;
}

State state() {
    if (!packaged()) return registryState(runValue);
    State current = unavailable;
    std::string failure;
    return task::state(current, failure) ? current : unavailable;
}

bool set(bool enabled, State &reached, std::string &failure) {
    if (packaged()) return task::set(enabled, reached, failure);
    const std::wstring path = executablePath();
    if (path.empty()) { failure = systemError("Finding this app's executable"); return false; }
    if (!setRegistry(runValue, L"\"" + path + L"\" " + launchArgument, enabled, failure)) return false;
    reached = registryState(runValue);
    return true;
}

// Exercises the registry path under a name of its own, so a user's real login
// item is never touched; packaged, only reads the startup task's state unless
// it is plainly off, then turns it on and off again.
bool selfTest(std::string &failure) {
    if (packaged()) {
        State current = unavailable;
        if (!task::state(current, failure)) return false;
        if (current != off) return true;
        State reached = unavailable;
        if (!task::set(true, reached, failure)) return false;
        State restored = unavailable;
        if (!task::set(false, restored, failure)) return false;
        if (reached != on || restored != off) {
            failure = "Launch at login: the startup task did not turn on and off.";
            return false;
        }
        return true;
    }
    constexpr wchar_t name[] = L"JustSpeakToIt.SelfTest";
    const std::wstring command = L"\"C:\\Program Files\\Just Speak\\SpeakWindows.exe\" --background";
    if (!setRegistry(name, command, true, failure)) return false;
    const bool registered = registryState(name) == on;
    // Task Manager's Disabled, then the app's own switch turning it on again.
    // A user who never opened Task Manager may have no StartupApproved key yet.
    const BYTE disabled[12] = {3};
    HKEY approvals = nullptr;
    LSTATUS approval = RegCreateKeyExW(HKEY_CURRENT_USER, approvedKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
                                       &approvals, nullptr);
    if (present(approval)) {
        approval = RegSetValueExW(approvals, name, 0, REG_BINARY, disabled, sizeof disabled);
        RegCloseKey(approvals);
    }
    const bool honoured = present(approval) && registryState(name) == off;
    const bool reenabled = setRegistry(name, command, true, failure) && registryState(name) == on;
    const bool removed = setRegistry(name, command, false, failure) && registryState(name) == off;
    RegDeleteKeyValueW(HKEY_CURRENT_USER, approvedKey, name);
    if (!registered || !honoured || !reenabled || !removed) {
        if (failure.empty()) failure = "Launch at login: the Run value did not follow the switch.";
        return false;
    }
    return true;
}

} // namespace jsti::login

int jsti_login_item_state(void) { return jsti::login::state(); }

int jsti_login_item_set(int enabled, int *reached, char *error, size_t capacity) {
    if (!reached || (enabled != 0 && enabled != 1)) return jsti::fail("Invalid login item request.", error, capacity);
    jsti::login::State state = jsti::login::unavailable;
    std::string failure;
    if (!jsti::login::set(enabled == 1, state, failure)) return jsti::fail(failure, error, capacity);
    *reached = state;
    return 0;
}

int jsti_login_item_launched(void) { return jsti::login::launchedAtLogin() ? 1 : 0; }

int jsti_login_item_self_test(char *error, size_t capacity) {
    std::string failure;
    return jsti::login::selfTest(failure) ? 0 : jsti::fail(failure, error, capacity);
}
