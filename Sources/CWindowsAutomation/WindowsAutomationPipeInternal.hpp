// The automation pipe's shared pieces: connection framing and the client
// (WindowsAutomationPipe.cpp), the server's listener
// (WindowsAutomationPipeListener.cpp), the user and integrity checks
// (WindowsAutomationPipeSecurity.cpp) and the self-test
// (WindowsAutomationPipeSelfTest.cpp). Not public ABI.
#pragma once

#include "include/CWindowsAutomation.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

// Same-user named pipes for the automation CLI. Every pipe instance is
// overlapped so each wait also observes a deadline and, on the server, the
// listener's stop event; nothing polls. Error text names the operation and a
// numeric Windows code only, never request or reply bytes.

namespace jsti::automation {

constexpr DWORD bufferBytes = 64 * 1024;

// Copies `message` into the caller's error buffer and returns `status`.
int fail(int status, const std::string &message, char *error, size_t capacity);
// Names the operation and the numeric Windows code, never request or reply bytes.
int systemFail(int status, const char *operation, DWORD code, char *error, size_t capacity);
// Only \\.\pipe\<leaf> with a non-empty leaf and no further separator.
bool localPipeName(const char *name, std::wstring &result);

struct Handle {
    HANDLE value = nullptr;
    Handle() = default;
    explicit Handle(HANDLE handle) : value(handle) {}
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};

struct Operation {
    OVERLAPPED overlapped{};
    Handle event;
    Operation() : event(CreateEventW(nullptr, TRUE, FALSE, nullptr)) { overlapped.hEvent = event.value; }
};

// Security (WindowsAutomationPipeSecurity.cpp).
// The process user's SID, copied so it outlives the token buffer.
std::vector<BYTE> processUser(DWORD &code);
// Owner and only grantee: the user. Network logons are denied explicitly.
bool pipeSecurity(PSECURITY_DESCRIPTOR &descriptor, DWORD &code);
// The client that wrote the first bytes: this user, not a network logon, and
// not below this process's integrity level.
bool trustedClient(HANDLE pipe);
std::string utf8(const wchar_t *text);

} // namespace jsti::automation

struct JSTIAutomationPipeListener;

struct JSTIAutomationPipeConnection {
    HANDLE pipe = INVALID_HANDLE_VALUE;
    bool server = false;
    bool verified = false;
    std::shared_ptr<JSTIAutomationPipeListener> listener;
};

struct JSTIAutomationPipeListener : std::enable_shared_from_this<JSTIAutomationPipeListener> {
    std::wstring name;
    DWORD maxInstances = 1;
    PSECURITY_DESCRIPTOR security = nullptr;
    jsti::automation::Handle stopEvent{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    jsti::automation::Handle slotEvent{CreateEventW(nullptr, FALSE, FALSE, nullptr)};
    std::mutex mutex;
    std::condition_variable idle;
    HANDLE pending = INVALID_HANDLE_VALUE;
    std::set<JSTIAutomationPipeConnection *> connections;
    unsigned busy = 0;
    bool stopped = false;
    std::shared_ptr<JSTIAutomationPipeListener> self;

    ~JSTIAutomationPipeListener() {
        if (pending != INVALID_HANDLE_VALUE) CloseHandle(pending);
        if (security) LocalFree(security);
    }

    HANDLE createInstance(bool first, DWORD &code) {
        SECURITY_ATTRIBUTES attributes{sizeof(attributes), security, FALSE};
        HANDLE pipe = CreateNamedPipeW(name.c_str(),
            PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0),
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            maxInstances, jsti::automation::bufferBytes, jsti::automation::bufferBytes, 0, &attributes);
        if (pipe == INVALID_HANDLE_VALUE) code = GetLastError();
        return pipe;
    }
};

namespace jsti::automation {

inline bool listenerStopped(const std::shared_ptr<JSTIAutomationPipeListener> &listener) {
    return listener && WaitForSingleObject(listener->stopEvent.value, 0) == WAIT_OBJECT_0;
}

// RAII marker so stop() waits for in-progress server I/O to acknowledge.
struct BusyScope {
    std::shared_ptr<JSTIAutomationPipeListener> listener;
    bool admitted = true;
    explicit BusyScope(const std::shared_ptr<JSTIAutomationPipeListener> &owner) : listener(owner) {
        if (!listener) return;
        std::lock_guard<std::mutex> lock(listener->mutex);
        if (listener->stopped) { admitted = false; return; }
        ++listener->busy;
    }
    ~BusyScope() {
        if (!listener || !admitted) return;
        std::lock_guard<std::mutex> lock(listener->mutex);
        --listener->busy;
        listener->idle.notify_all();
    }
};

} // namespace jsti::automation
