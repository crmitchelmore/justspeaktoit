#include "WindowsGlobalEscape.hpp"
#include <atomic>
#include <mutex>

namespace jsti::globalEscape {
namespace {
class Epoch {
    std::atomic<UINT_PTR> value{0};
    std::mutex mutex;
    bool recording = false, allowed = true, voiceEdit = false;
    void refresh() {
        const auto prior = value.load();
        if (static_cast<bool>(prior & 1u) != ((recording && allowed) || voiceEdit)) value.store(prior + 1);
    }
public:
    UINT_PTR current() const { return value.load(); }
    void publish(bool active) {
        std::lock_guard<std::mutex> lock(mutex);
        recording = active;
        refresh();
    }
    void configure(bool enabled) {
        std::lock_guard<std::mutex> lock(mutex);
        allowed = enabled;
        refresh();
    }
    bool enabled() {
        std::lock_guard<std::mutex> lock(mutex);
        return allowed || voiceEdit;
    }
    void editing(bool active) {
        std::lock_guard<std::mutex> lock(mutex);
        voiceEdit = active;
        refresh();
    }
    void close() {
        std::lock_guard<std::mutex> lock(mutex);
        recording = voiceEdit = false;
        refresh();
    }
};

bool externalForeground() {
    DWORD process = 0;
    HWND foreground = GetForegroundWindow();
    return foreground && GetWindowThreadProcessId(foreground, &process) &&
        process && process != GetCurrentProcessId();
}

struct Native {
    decltype(&SetWindowsHookExW) install = SetWindowsHookExW;
    decltype(&UnhookWindowsHookEx) remove = UnhookWindowsHookEx;
    decltype(&GetAsyncKeyState) keyState = GetAsyncKeyState;
    decltype(&PostMessageW) post = PostMessageW;
    decltype(&CallNextHookEx) next = CallNextHookEx;
    bool (*external)() = externalForeground;
};

LRESULT CALLBACK hook(int code, WPARAM kind, LPARAM data);

class Listener {
    Epoch &requested;
    Native native;
    HHOOK handle = nullptr;
    HWND owner = nullptr;
    UINT_PTR token = 0, failedEpoch = 0;
    bool held = false, pending = false, removalReported = false;
    Failure report = nullptr;
public:
    Listener(Epoch &epoch, Native operations = {}) : requested(epoch), native(operations) {}

    bool accepting() const { return owner && handle && (token & 1u) && token == requested.current(); }

    bool stop(std::string &failure) {
        failure.clear();
        owner = nullptr; token = 0; held = pending = false; report = nullptr;
        if (handle && !native.remove(handle)) {
            const auto code = GetLastError();
            if (code == ERROR_INVALID_HOOK_HANDLE) handle = nullptr;
            if (!removalReported) {
                failure = systemError("Removing the active-only Escape listener", code);
                removalReported = true;
            }
            return false;
        }
        handle = nullptr;
        removalReported = false;
        return true;
    }

    bool reconcile(HWND window, bool enabled, Failure onFailure, std::string &failure) {
        failure.clear();
        const auto desired = requested.current();
        if (enabled && owner == window && accepting()) return true;
        if (!stop(failure)) return false;
        if (!enabled || !(desired & 1u)) return true;
        if (failedEpoch == desired) return false;
        handle = native.install(WH_KEYBOARD_LL, hook, GetModuleHandleW(nullptr), 0);
        if (!handle) {
            failedEpoch = desired;
            failure = systemError("Installing the active-only Escape listener") +
                " Use Cancel in the app window.";
            return false;
        }
        owner = window; token = desired; report = onFailure;
        held = (native.keyState(VK_ESCAPE) & 0x8000) != 0;
        return true;
    }

    bool take(HWND window, WPARAM delivered) {
        if (!accepting() || owner != window || delivered != token || !pending) return false;
        pending = false;
        return true;
    }

    LRESULT route(int code, WPARAM kind, LPARAM data) {
        // No event payload, modifier or foreground inspection without live work.
        if (code == HC_ACTION && accepting() && data) {
            const auto &event = *reinterpret_cast<const KBDLLHOOKSTRUCT *>(data);
            if (event.vkCode == VK_ESCAPE && !(event.flags & (LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED))) {
                if (kind == WM_KEYUP || kind == WM_SYSKEYUP) held = false;
                else if (kind == WM_KEYDOWN || kind == WM_SYSKEYDOWN) {
                    const bool first = !held;
                    held = true;
                    bool plain = !(event.flags & LLKHF_ALTDOWN);
                    for (int modifier : {VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN})
                        plain = plain && !(native.keyState(modifier) & 0x8000);
                    if (first && !pending && plain && native.external()) {
                        pending = true;
                        if (!native.post(owner, message, token, 0)) {
                            pending = false;
                            const auto failure = systemError("Queueing Escape cancellation");
                            if (report) report(owner, failure);
                        }
                    }
                }
            }
        }
        // This is observation, never a key grab: the foreground app still gets Escape.
        return native.next(nullptr, code, kind, data);
    }
};

Epoch requested;
Listener listener(requested);

LRESULT CALLBACK hook(int code, WPARAM kind, LPARAM data) {
    return listener.route(code, kind, data);
}

struct Fixture {
    int installs = 0, removals = 0, posts = 0, chains = 0, reports = 0, modifier = 0;
    int keyReads = 0, foregroundReads = 0;
    bool installFails = false, removeFails = false, postFails = false, external = true, held = false;
    WPARAM delivered = 0;
};
Fixture *fixture = nullptr;

HHOOK WINAPI installFixture(int kind, HOOKPROC callback, HINSTANCE module, DWORD thread) {
    ++fixture->installs;
    if (fixture->installFails || kind != WH_KEYBOARD_LL || !callback || !module || thread != 0) {
        SetLastError(ERROR_ACCESS_DENIED);
        return nullptr;
    }
    return reinterpret_cast<HHOOK>(static_cast<UINT_PTR>(1));
}
BOOL WINAPI removeFixture(HHOOK) {
    ++fixture->removals;
    SetLastError(ERROR_ACCESS_DENIED);
    return fixture->removeFails ? FALSE : TRUE;
}
SHORT WINAPI keyFixture(int key) {
    ++fixture->keyReads;
    return (key == VK_ESCAPE ? fixture->held : key == fixture->modifier) ? static_cast<SHORT>(0x8000) : 0;
}
BOOL WINAPI postFixture(HWND, UINT kind, WPARAM token, LPARAM) {
    ++fixture->posts;
    fixture->delivered = token;
    SetLastError(ERROR_NOT_ENOUGH_QUOTA);
    return !fixture->postFails && kind == message;
}
LRESULT WINAPI nextFixture(HHOOK, int, WPARAM, LPARAM) { ++fixture->chains; return 517; }
bool externalFixture() { ++fixture->foregroundReads; return fixture->external; }
void reportFixture(HWND, const std::string &failure) { if (!failure.empty()) ++fixture->reports; }

bool checkKeys(HWND window, std::string &failure) {
    Fixture state;
    fixture = &state;
    Epoch epoch;
    Listener test(epoch, {installFixture, removeFixture, keyFixture, postFixture, nextFixture, externalFixture});
    KBDLLHOOKSTRUCT event{};
    event.vkCode = VK_ESCAPE;
    auto key = [&](WPARAM kind = WM_KEYDOWN, int code = HC_ACTION) {
        return test.route(code, kind, reinterpret_cast<LPARAM>(&event)) == 517;
    };
    bool okay = test.reconcile(window, true, reportFixture, failure) && state.installs == 0 && key();
    okay = test.route(HC_ACTION, WM_KEYDOWN, 1) == 517 &&
        state.keyReads == 0 && state.foregroundReads == 0 && okay;
    epoch.publish(true);
    okay = test.reconcile(window, false, reportFixture, failure) && state.installs == 0 && okay;
    okay = test.reconcile(window, true, reportFixture, failure) &&
        test.reconcile(window, true, reportFixture, failure) && state.installs == 1 && okay;
    okay = test.route(-1, WM_KEYDOWN, 1) == 517 &&
        test.route(HC_ACTION, WM_KEYDOWN, 0) == 517 && okay;
    event.vkCode = 'A';
    okay = key() && key(WM_KEYDOWN, -1) && state.posts == 0 && okay;
    event.vkCode = VK_ESCAPE;
    for (DWORD flags : {DWORD(LLKHF_INJECTED), DWORD(LLKHF_LOWER_IL_INJECTED)}) {
        event.flags = flags;
        okay = key() && state.posts == 0 && okay;
    }
    event.flags = 0;
    for (int modifier : {VK_CONTROL, VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN}) {
        state.modifier = modifier;
        okay = key() && state.posts == 0 && okay;
        state.modifier = 0;
        okay = key() && state.posts == 0 && key(WM_KEYUP) && okay;
    }
    event.flags = LLKHF_ALTDOWN;
    okay = key(WM_SYSKEYDOWN) && state.posts == 0 && key(WM_SYSKEYUP) && okay;
    event.flags = 0;
    state.external = false;
    okay = key() && state.posts == 0 && okay;
    state.external = true;
    okay = key() && state.posts == 0 && key(WM_KEYUP) && okay;
    okay = key() && state.posts == 1 && !test.take(nullptr, state.delivered) &&
        !test.take(window, state.delivered + 1) && test.take(window, state.delivered) &&
        !test.take(window, state.delivered) && key() && state.posts == 1 && key(WM_KEYUP) && okay;
    okay = key() && state.posts == 2 && key(WM_KEYUP) && key() && state.posts == 2 && okay;
    const auto old = state.delivered;
    epoch.publish(false);
    okay = !test.accepting() && !test.take(window, old) && key() && state.posts == 2 && okay;
    epoch.publish(true);
    okay = test.reconcile(window, true, reportFixture, failure) && state.installs == 2 &&
        state.removals == 1 && !test.take(window, old) && okay;
    state.postFails = true;
    okay = key() && state.posts == 3 && state.reports == 1 && !test.take(window, state.delivered) && okay;
    state.postFails = false;
    okay = key(WM_KEYUP) && key() && state.posts == 4 && test.take(window, state.delivered) && okay;
    for (int lock : {VK_CAPITAL, VK_NUMLOCK, VK_SCROLL}) {
        const auto posts = state.posts;
        state.modifier = lock;
        okay = key(WM_KEYUP) && key() && state.posts == posts + 1 &&
            test.take(window, state.delivered) && okay;
    }
    state.modifier = 0;
    epoch.publish(false);
    const auto reads = state.keyReads;
    okay = test.reconcile(window, true, reportFixture, failure) && state.removals == 2 &&
        key() && !test.accepting() && state.posts == 7 && state.keyReads == reads &&
        state.chains > 20 && okay;
    okay = test.stop(failure) && state.removals == 2 && okay;
    fixture = nullptr;
    return okay;
}

bool checkLifecycle(HWND window, std::string &failure) {
    Fixture state;
    fixture = &state;
    Epoch epoch;
    Listener test(epoch, {installFixture, removeFixture, keyFixture, postFixture, nextFixture, externalFixture});
    epoch.publish(true);
    state.installFails = true;
    bool okay = !test.reconcile(window, true, reportFixture, failure) && !failure.empty() &&
        !test.accepting() && state.installs == 1;
    okay = !test.reconcile(window, true, reportFixture, failure) && failure.empty() && state.installs == 1 && okay;
    epoch.publish(false); epoch.publish(true);
    state.installFails = false;
    state.held = true;
    okay = test.reconcile(window, true, reportFixture, failure) && state.installs == 2 && okay;
    KBDLLHOOKSTRUCT event{};
    event.vkCode = VK_ESCAPE;
    auto key = [&](WPARAM kind) {
        return test.route(HC_ACTION, kind, reinterpret_cast<LPARAM>(&event)) == 517;
    };
    okay = key(WM_KEYDOWN) && state.posts == 0 && key(WM_KEYUP) && key(WM_KEYDOWN) &&
        state.posts == 1 && okay;
    epoch.publish(false);
    state.removeFails = true;
    okay = !test.reconcile(window, true, reportFixture, failure) && !failure.empty() &&
        !test.accepting() && !test.take(window, state.delivered) && okay;
    epoch.publish(true);
    okay = !test.reconcile(window, true, reportFixture, failure) && failure.empty() &&
        state.installs == 2 && key(WM_KEYDOWN) && state.posts == 1 && okay;
    state.removeFails = false;
    state.held = false;
    okay = test.reconcile(window, true, reportFixture, failure) && state.installs == 3 && okay;
    epoch.publish(false); epoch.publish(true);
    okay = !test.accepting() && !test.take(window, state.delivered) && okay;
    okay = test.stop(failure) && !test.accepting() && test.stop(failure) && okay;
    fixture = nullptr;
    return okay;
}

bool checkPolicy(HWND window, std::string &failure) {
    Fixture state;
    fixture = &state;
    Epoch epoch;
    Listener test(epoch, {installFixture, removeFixture, keyFixture, postFixture, nextFixture, externalFixture});
    epoch.publish(true);
    bool okay = test.reconcile(window, true, reportFixture, failure) && state.installs == 1;
    const auto first = epoch.current();
    epoch.configure(false);
    okay = !epoch.enabled() && !(epoch.current() & 1u) && !test.accepting() &&
        test.reconcile(window, true, reportFixture, failure) && state.removals == 1 && okay;
    epoch.publish(false); epoch.publish(true);
    okay = !(epoch.current() & 1u) && okay;
    epoch.configure(true);
    okay = epoch.enabled() && epoch.current() != first && (epoch.current() & 1u) &&
        test.reconcile(window, true, reportFixture, failure) && state.installs == 2 && okay;
    epoch.configure(false);
    epoch.editing(true);
    const auto editing = epoch.current();
    okay = epoch.enabled() && (editing & 1u) &&
        test.reconcile(window, true, reportFixture, failure) && test.accepting() && okay;
    epoch.publish(false);
    okay = epoch.current() == editing && okay;
    epoch.editing(false);
    okay = !epoch.enabled() && !(epoch.current() & 1u) && !test.accepting() && okay;
    epoch.editing(true);
    epoch.close();
    okay = !(epoch.current() & 1u) && !test.accepting() && test.stop(failure) && okay;
    fixture = nullptr;
    return okay;
}
}

void publish(int recording) { requested.publish(recording == 1 || recording == 2); }
void configure(bool enabled) { requested.configure(enabled); }
void editing(bool active) { requested.editing(active); }
bool enabled() { return requested.enabled(); }
uint64_t token() {
    const auto value = requested.current();
    return value & 1u ? value : 0;
}

bool reconcile(HWND window, bool enabled, Failure report, std::string &failure) {
    return listener.reconcile(window, enabled, report, failure);
}

bool take(HWND window, WPARAM token) { return listener.take(window, token); }

bool current(uint64_t token) { return (token & 1u) && token == requested.current(); }

bool stop(std::string &failure) {
    requested.close();
    return listener.stop(failure);
}

bool selfTest(HWND window, std::string &failure) {
    if (!checkKeys(window, failure) || !checkLifecycle(window, failure) || !checkPolicy(window, failure)) {
        failure = "Active-only global Escape lost passive delivery, scope, generation or teardown guards.";
        return false;
    }
    failure.clear();
    return true;
}
}
