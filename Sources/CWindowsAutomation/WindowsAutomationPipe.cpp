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
#include <aclapi.h>
#include <sddl.h>
#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

// Same-user named pipes for the automation CLI. Every pipe instance is
// overlapped so each wait also observes a deadline and, on the server, the
// listener's stop event; nothing polls. Error text names the operation and a
// numeric Windows code only, never request or reply bytes.

namespace {
constexpr DWORD bufferBytes = 64 * 1024;
const wchar_t localPrefix[] = L"\\\\.\\pipe\\";

int fail(int status, const std::string &message, char *error, size_t capacity) {
    if (error && capacity) {
        const size_t count = std::min(message.size(), capacity - 1);
        std::memcpy(error, message.data(), count);
        error[count] = 0;
    }
    return status;
}

int systemFail(int status, const char *operation, DWORD code, char *error, size_t capacity) {
    return fail(status, std::string(operation) + " failed (Windows error " + std::to_string(code) + ").", error,
                capacity);
}

bool wide(const char *text, std::wstring &result) {
    if (!text) return false;
    const size_t length = std::strlen(text);
    if (!length) { result.clear(); return true; }
    if (length > 32767) return false;
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, static_cast<int>(length), nullptr, 0);
    if (!size) return false;
    result.resize(static_cast<size_t>(size));
    return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, static_cast<int>(length), &result[0], size) != 0;
}

std::string utf8(const wchar_t *text) {
    const int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (size <= 1) return {};
    std::string result(static_cast<size_t>(size), 0);
    WideCharToMultiByte(CP_UTF8, 0, text, -1, &result[0], size, nullptr, nullptr);
    result.resize(static_cast<size_t>(size - 1));
    return result;
}

// Only \\.\pipe\<leaf> with a non-empty leaf and no further separator.
bool localPipeName(const char *name, std::wstring &result) {
    std::wstring candidate;
    if (!wide(name, candidate) || candidate.size() > 256) return false;
    const size_t prefix = std::wcslen(localPrefix);
    if (candidate.size() <= prefix || CompareStringOrdinal(candidate.c_str(), static_cast<int>(prefix), localPrefix,
                                                           static_cast<int>(prefix), TRUE) != CSTR_EQUAL) {
        return false;
    }
    for (size_t index = prefix; index < candidate.size(); ++index) {
        if (candidate[index] == L'\\' || candidate[index] == L'/' || candidate[index] < 0x20) return false;
    }
    result = localPrefix + candidate.substr(prefix);
    return true;
}

struct Handle {
    HANDLE value = nullptr;
    Handle() = default;
    explicit Handle(HANDLE handle) : value(handle) {}
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};

// The process user's SID, copied so it outlives the token buffer.
std::vector<BYTE> processUser(DWORD &code) {
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) { code = GetLastError(); return {}; }
    Handle token(raw);
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (!size || !GetTokenInformation(token.value, TokenUser, buffer.data(), size, &size)) {
        code = GetLastError();
        return {};
    }
    const PSID sid = reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid;
    std::vector<BYTE> copy(GetLengthSid(sid));
    if (!CopySid(static_cast<DWORD>(copy.size()), copy.data(), sid)) { code = GetLastError(); return {}; }
    return copy;
}

DWORD integrityLevel(HANDLE token) {
    DWORD size = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (!size || !GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), size, &size)) return 0;
    const PSID sid = reinterpret_cast<TOKEN_MANDATORY_LABEL *>(buffer.data())->Label.Sid;
    return *GetSidSubAuthority(sid, static_cast<DWORD>(*GetSidSubAuthorityCount(sid) - 1));
}

DWORD processIntegrity() {
    HANDLE raw = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw)) return SECURITY_MANDATORY_HIGH_RID;
    Handle token(raw);
    return integrityLevel(token.value);
}

bool hasNetworkGroup(HANDLE token) {
    DWORD size = 0;
    GetTokenInformation(token, TokenGroups, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (!size || !GetTokenInformation(token, TokenGroups, buffer.data(), size, &size)) return true;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;
    PSID network = nullptr;
    if (!AllocateAndInitializeSid(&authority, 1, SECURITY_NETWORK_RID, 0, 0, 0, 0, 0, 0, 0, &network)) return true;
    const auto *groups = reinterpret_cast<TOKEN_GROUPS *>(buffer.data());
    bool found = false;
    for (DWORD index = 0; index < groups->GroupCount && !found; ++index) {
        found = (groups->Groups[index].Attributes & SE_GROUP_ENABLED) && EqualSid(groups->Groups[index].Sid, network);
    }
    FreeSid(network);
    return found;
}

// Owner and only grantee: the user. Network logons are denied explicitly.
bool pipeSecurity(PSECURITY_DESCRIPTOR &descriptor, DWORD &code) {
    const std::vector<BYTE> user = processUser(code);
    if (user.empty()) return false;
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(const_cast<BYTE *>(user.data()), &text)) { code = GetLastError(); return false; }
    const std::wstring sid(text);
    LocalFree(text);
    const std::wstring sddl = L"O:" + sid + L"D:P(D;;GA;;;NU)(A;;GA;;;" + sid + L")";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
        code = GetLastError();
        return false;
    }
    return true;
}

struct Operation {
    OVERLAPPED overlapped{};
    Handle event;
    Operation() : event(CreateEventW(nullptr, TRUE, FALSE, nullptr)) { overlapped.hEvent = event.value; }
};
} // namespace

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
    Handle stopEvent{CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    Handle slotEvent{CreateEventW(nullptr, FALSE, FALSE, nullptr)};
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
            maxInstances, bufferBytes, bufferBytes, 0, &attributes);
        if (pipe == INVALID_HANDLE_VALUE) code = GetLastError();
        return pipe;
    }
};

namespace {
bool listenerStopped(const std::shared_ptr<JSTIAutomationPipeListener> &listener) {
    return listener && WaitForSingleObject(listener->stopEvent.value, 0) == WAIT_OBJECT_0;
}

// Waits for one overlapped operation, the deadline or (server) the stop event.
// Always leaves the operation complete, so its buffer can be released.
int finish(JSTIAutomationPipeConnection *connection, Operation &operation, BOOL started, DWORD timeout,
           DWORD &transferred, const char *what, char *error, size_t capacity) {
    DWORD code = started ? ERROR_SUCCESS : GetLastError();
    if (!started && code != ERROR_IO_PENDING) {
        if (code == ERROR_BROKEN_PIPE || code == ERROR_PIPE_NOT_CONNECTED || code == ERROR_NO_DATA) {
            return fail(JSTI_AUTOMATION_PIPE_CLOSED, "The automation peer closed the connection.", error, capacity);
        }
        if (code == ERROR_OPERATION_ABORTED || code == ERROR_INVALID_HANDLE) {
            return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
        }
        return systemFail(JSTI_AUTOMATION_PIPE_FAILED, what, code, error, capacity);
    }
    HANDLE waits[] = {operation.event.value, connection->listener ? connection->listener->stopEvent.value : nullptr};
    const DWORD count = connection->listener ? 2 : 1;
    const DWORD outcome = WaitForMultipleObjects(count, waits, FALSE, timeout);
    int status = JSTI_AUTOMATION_PIPE_OK;
    if (outcome != WAIT_OBJECT_0) {
        CancelIoEx(connection->pipe, &operation.overlapped);
        status = outcome == WAIT_OBJECT_0 + 1 ? JSTI_AUTOMATION_PIPE_CANCELLED : JSTI_AUTOMATION_PIPE_TIMED_OUT;
    }
    if (!GetOverlappedResult(connection->pipe, &operation.overlapped, &transferred, TRUE)) {
        code = GetLastError();
        if (status != JSTI_AUTOMATION_PIPE_OK) {
            return fail(status, status == JSTI_AUTOMATION_PIPE_CANCELLED ? "The automation listener stopped."
                : "The automation peer did not respond in time.", error, capacity);
        }
        if (code == ERROR_BROKEN_PIPE || code == ERROR_PIPE_NOT_CONNECTED || code == ERROR_NO_DATA) {
            return fail(JSTI_AUTOMATION_PIPE_CLOSED, "The automation peer closed the connection.", error, capacity);
        }
        if (code == ERROR_OPERATION_ABORTED) {
            return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
        }
        return systemFail(JSTI_AUTOMATION_PIPE_FAILED, what, code, error, capacity);
    }
    // Completed despite a racing deadline: keep the bytes that did arrive.
    return JSTI_AUTOMATION_PIPE_OK;
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

int transfer(JSTIAutomationPipeConnection *connection, uint8_t *bytes, size_t count, uint32_t timeout, bool writing,
             char *error, size_t capacity) {
    if (!connection || (count && !bytes)) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "Invalid automation pipe transfer.", error, capacity);
    }
    BusyScope busy(connection->listener);
    if (!busy.admitted || connection->pipe == INVALID_HANDLE_VALUE) {
        return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
    }
    const ULONGLONG deadline = GetTickCount64() + timeout;
    size_t done = 0;
    while (done < count) {
        const ULONGLONG now = GetTickCount64();
        const DWORD remaining = now >= deadline ? 0 : static_cast<DWORD>(deadline - now);
        const DWORD chunk = static_cast<DWORD>(std::min<size_t>(count - done, bufferBytes));
        Operation operation;
        if (!operation.event.value) {
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create automation I/O event", GetLastError(), error, capacity);
        }
        DWORD transferred = 0;
        const BOOL started = writing
            ? WriteFile(connection->pipe, bytes + done, chunk, nullptr, &operation.overlapped)
            : ReadFile(connection->pipe, bytes + done, chunk, nullptr, &operation.overlapped);
        const int status = finish(connection, operation, started, remaining, transferred,
                                  writing ? "Write automation pipe" : "Read automation pipe", error, capacity);
        if (status != JSTI_AUTOMATION_PIPE_OK) return status;
        if (!transferred) {
            return fail(JSTI_AUTOMATION_PIPE_CLOSED, "The automation peer closed the connection.", error, capacity);
        }
        done += transferred;
    }
    return JSTI_AUTOMATION_PIPE_OK;
}

// The client that wrote the first bytes: this user, not a network logon, and
// not below this process's integrity level.
bool trustedClient(HANDLE pipe) {
    if (!ImpersonateNamedPipeClient(pipe)) return false;
    HANDLE raw = nullptr;
    const BOOL opened = OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, TRUE, &raw);
    RevertToSelf();
    if (!opened) return false;
    Handle token(raw);
    DWORD code = 0;
    const std::vector<BYTE> user = processUser(code);
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    if (user.empty() || !size || !GetTokenInformation(token.value, TokenUser, buffer.data(), size, &size)) return false;
    const PSID client = reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid;
    return EqualSid(client, const_cast<BYTE *>(user.data())) && !hasNetworkGroup(token.value) &&
        integrityLevel(token.value) >= processIntegrity();
}
} // namespace

int jsti_automation_user_sid(char *sid, size_t capacity, size_t *required, char *error, size_t errorCapacity) {
    DWORD code = 0;
    const std::vector<BYTE> user = processUser(code);
    if (user.empty()) return systemFail(-1, "Read the current user", code, error, errorCapacity);
    LPWSTR text = nullptr;
    if (!ConvertSidToStringSidW(const_cast<BYTE *>(user.data()), &text)) {
        return systemFail(-1, "Format the current user", GetLastError(), error, errorCapacity);
    }
    const std::string value = utf8(text);
    LocalFree(text);
    if (required) *required = value.size() + 1;
    if (!sid || capacity < value.size() + 1) return sid ? 2 : 0;
    std::memcpy(sid, value.c_str(), value.size() + 1);
    return 0;
}

int jsti_automation_pipe_listen(const char *pipeName, uint32_t maxInstances, JSTIAutomationPipeListener **result,
                                char *error, size_t capacity) {
    if (!result) return fail(JSTI_AUTOMATION_PIPE_FAILED, "No listener output supplied.", error, capacity);
    *result = nullptr;
    std::wstring name;
    if (!localPipeName(pipeName, name) || maxInstances < 1 || maxInstances > 64) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "The automation pipe name or instance count is invalid.", error,
                    capacity);
    }
    try {
        auto listener = std::make_shared<JSTIAutomationPipeListener>();
        listener->name = name;
        listener->maxInstances = maxInstances;
        DWORD code = 0;
        if (!listener->stopEvent.value || !listener->slotEvent.value || !pipeSecurity(listener->security, code)) {
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Prepare the automation pipe", code ? code : GetLastError(),
                              error, capacity);
        }
        listener->pending = listener->createInstance(true, code);
        if (listener->pending == INVALID_HANDLE_VALUE) {
            if (code == ERROR_ACCESS_DENIED || code == ERROR_PIPE_BUSY) {
                return fail(JSTI_AUTOMATION_PIPE_IN_USE, "Another process already owns the automation pipe.", error,
                            capacity);
            }
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create the automation pipe", code, error, capacity);
        }
        listener->self = listener;
        *result = listener.get();
        return JSTI_AUTOMATION_PIPE_OK;
    } catch (const std::exception &) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "Could not allocate the automation listener.", error, capacity);
    }
}

int jsti_automation_pipe_accept(JSTIAutomationPipeListener *raw, JSTIAutomationPipeConnection **result, char *error,
                                size_t capacity) {
    if (!raw || !result) return fail(JSTI_AUTOMATION_PIPE_FAILED, "Invalid automation accept.", error, capacity);
    *result = nullptr;
    const std::shared_ptr<JSTIAutomationPipeListener> listener = raw->self;
    if (!listener) return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
    while (true) {
        HANDLE pipe = INVALID_HANDLE_VALUE;
        {
            std::lock_guard<std::mutex> lock(listener->mutex);
            if (listener->stopped) {
                return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
            }
            if (listener->pending == INVALID_HANDLE_VALUE) {
                DWORD code = 0;
                listener->pending = listener->createInstance(false, code);
                if (listener->pending == INVALID_HANDLE_VALUE && code != ERROR_PIPE_BUSY) {
                    return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create an automation pipe instance", code, error,
                                      capacity);
                }
            }
            pipe = listener->pending;
        }
        if (pipe == INVALID_HANDLE_VALUE) {
            // Every instance is serving a client: wait for one to close.
            HANDLE waits[] = {listener->slotEvent.value, listener->stopEvent.value};
            WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            continue;
        }
        // Counted as in-progress I/O, so stop never closes the instance under this wait.
        BusyScope busy(listener);
        if (!busy.admitted) {
            return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
        }
        Operation operation;
        if (!operation.event.value) {
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Create automation accept event", GetLastError(), error,
                              capacity);
        }
        bool connected = ConnectNamedPipe(pipe, &operation.overlapped) != FALSE;
        DWORD code = connected ? ERROR_SUCCESS : GetLastError();
        if (!connected && code == ERROR_PIPE_CONNECTED) connected = true;
        if (!connected && code == ERROR_IO_PENDING) {
            HANDLE waits[] = {operation.event.value, listener->stopEvent.value};
            const DWORD outcome = WaitForMultipleObjects(2, waits, FALSE, INFINITE);
            if (outcome != WAIT_OBJECT_0) CancelIoEx(pipe, &operation.overlapped);
            DWORD ignored = 0;
            connected = GetOverlappedResult(pipe, &operation.overlapped, &ignored, TRUE) != FALSE;
            code = connected ? ERROR_SUCCESS : GetLastError();
            if (outcome != WAIT_OBJECT_0) connected = false;
        }
        if (listenerStopped(listener)) {
            return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
        }
        if (!connected) {
            // A client that connected and vanished: recycle the instance.
            DisconnectNamedPipe(pipe);
            if (code == ERROR_NO_DATA || code == ERROR_BROKEN_PIPE) continue;
            return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Accept an automation client", code, error, capacity);
        }
        try {
            auto *connection = new JSTIAutomationPipeConnection();
            connection->pipe = pipe;
            connection->server = true;
            connection->listener = listener;
            std::lock_guard<std::mutex> lock(listener->mutex);
            if (listener->stopped) {
                delete connection;
                return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation listener stopped.", error, capacity);
            }
            listener->connections.insert(connection);
            // A replacement instance keeps the name reachable while this client is served.
            DWORD ignored = 0;
            listener->pending = listener->createInstance(false, ignored);
            *result = connection;
            return JSTI_AUTOMATION_PIPE_OK;
        } catch (const std::exception &) {
            DisconnectNamedPipe(pipe);
            return fail(JSTI_AUTOMATION_PIPE_FAILED, "Could not allocate an automation connection.", error, capacity);
        }
    }
}

int jsti_automation_pipe_wait_for_stop(JSTIAutomationPipeListener *listener, uint32_t timeout) {
    if (!listener) return 1;
    return WaitForSingleObject(listener->stopEvent.value, timeout) == WAIT_OBJECT_0 ? 1 : 0;
}

int jsti_automation_pipe_stop(JSTIAutomationPipeListener *listener, uint32_t timeout) {
    if (!listener) return JSTI_AUTOMATION_PIPE_OK;
    std::unique_lock<std::mutex> lock(listener->mutex);
    listener->stopped = true;
    SetEvent(listener->stopEvent.value);
    if (listener->pending != INVALID_HANDLE_VALUE) CancelIoEx(listener->pending, nullptr);
    for (auto *connection : listener->connections) {
        if (connection->pipe != INVALID_HANDLE_VALUE) CancelIoEx(connection->pipe, nullptr);
    }
    if (!listener->idle.wait_for(lock, std::chrono::milliseconds(timeout), [&] { return listener->busy == 0; })) {
        return JSTI_AUTOMATION_PIPE_TIMED_OUT;
    }
    // Closing the pending instance can race the accept thread's wait; that
    // thread observes the stop event and never touches the handle again.
    if (listener->pending != INVALID_HANDLE_VALUE) {
        CloseHandle(listener->pending);
        listener->pending = INVALID_HANDLE_VALUE;
    }
    for (auto *connection : listener->connections) {
        if (connection->pipe != INVALID_HANDLE_VALUE) {
            DisconnectNamedPipe(connection->pipe);
            CloseHandle(connection->pipe);
            connection->pipe = INVALID_HANDLE_VALUE;
        }
    }
    return JSTI_AUTOMATION_PIPE_OK;
}

void jsti_automation_pipe_listener_release(JSTIAutomationPipeListener *listener) {
    if (!listener) return;
    jsti_automation_pipe_stop(listener, 5000);
    std::shared_ptr<JSTIAutomationPipeListener> keep;
    {
        std::lock_guard<std::mutex> lock(listener->mutex);
        keep.swap(listener->self);
    }
    // Remaining connections hold their own references.
}

int jsti_automation_pipe_connect(const char *pipeName, uint32_t timeout, JSTIAutomationPipeConnection **result,
                                 char *error, size_t capacity) {
    if (!result) return fail(JSTI_AUTOMATION_PIPE_FAILED, "No connection output supplied.", error, capacity);
    *result = nullptr;
    std::wstring name;
    if (!localPipeName(pipeName, name)) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "The automation pipe must be on this computer.", error, capacity);
    }
    const ULONGLONG deadline = GetTickCount64() + timeout;
    HANDLE pipe = INVALID_HANDLE_VALUE;
    while (true) {
        pipe = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                           FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) break;
        const DWORD code = GetLastError();
        if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) {
            return fail(JSTI_AUTOMATION_PIPE_NOT_FOUND, "Just Speak to It is not running or automation is off.", error,
                        capacity);
        }
        if (code == ERROR_ACCESS_DENIED) {
            return fail(JSTI_AUTOMATION_PIPE_ACCESS_DENIED, "This user may not open the automation pipe.", error,
                        capacity);
        }
        if (code != ERROR_PIPE_BUSY) return systemFail(JSTI_AUTOMATION_PIPE_FAILED, "Open the automation pipe", code,
                                                       error, capacity);
        const ULONGLONG now = GetTickCount64();
        if (now >= deadline) {
            return fail(JSTI_AUTOMATION_PIPE_TIMED_OUT, "The app is busy with other automation clients.", error,
                        capacity);
        }
        WaitNamedPipeW(name.c_str(), static_cast<DWORD>(std::min<ULONGLONG>(deadline - now, 0xFFFFFFFE)));
    }
    Handle owned(pipe);
    PSID owner = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    DWORD code = GetSecurityInfo(pipe, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION, &owner, nullptr, nullptr,
                                 nullptr, &descriptor);
    DWORD userCode = 0;
    const std::vector<BYTE> user = processUser(userCode);
    const bool trusted = code == ERROR_SUCCESS && owner && !user.empty() && EqualSid(owner, const_cast<BYTE *>(user.data()));
    if (descriptor) LocalFree(descriptor);
    if (!trusted) {
        return fail(JSTI_AUTOMATION_PIPE_UNTRUSTED, "The automation pipe is not owned by this user.", error, capacity);
    }
    try {
        auto *connection = new JSTIAutomationPipeConnection();
        connection->pipe = pipe;
        owned.value = nullptr;
        *result = connection;
        return JSTI_AUTOMATION_PIPE_OK;
    } catch (const std::exception &) {
        return fail(JSTI_AUTOMATION_PIPE_FAILED, "Could not allocate an automation connection.", error, capacity);
    }
}

int jsti_automation_pipe_read(JSTIAutomationPipeConnection *connection, uint8_t *bytes, size_t count,
                              uint32_t timeout, char *error, size_t capacity) {
    if (!connection || !count) return transfer(connection, bytes, count, timeout, false, error, capacity);
    if (!connection->server || connection->verified) return transfer(connection, bytes, count, timeout, false, error,
                                                                     capacity);
    // Impersonation needs data from the client, so read one byte first.
    const int first = transfer(connection, bytes, 1, timeout, false, error, capacity);
    if (first != JSTI_AUTOMATION_PIPE_OK) return first;
    if (!trustedClient(connection->pipe)) {
        return fail(JSTI_AUTOMATION_PIPE_UNTRUSTED, "The automation client is not this user on this computer.", error,
                    capacity);
    }
    connection->verified = true;
    return count == 1 ? JSTI_AUTOMATION_PIPE_OK : transfer(connection, bytes + 1, count - 1, timeout, false, error,
                                                           capacity);
}

int jsti_automation_pipe_write(JSTIAutomationPipeConnection *connection, const uint8_t *bytes, size_t count,
                               uint32_t timeout, char *error, size_t capacity) {
    return transfer(connection, const_cast<uint8_t *>(bytes), count, timeout, true, error, capacity);
}

int jsti_automation_pipe_drain(JSTIAutomationPipeConnection *connection, uint32_t timeout) {
    if (!connection || connection->pipe == INVALID_HANDLE_VALUE) return JSTI_AUTOMATION_PIPE_CANCELLED;
    const ULONGLONG deadline = GetTickCount64() + timeout;
    uint8_t discard[256];
    while (true) {
        const ULONGLONG now = GetTickCount64();
        const DWORD remaining = now >= deadline ? 0 : static_cast<DWORD>(deadline - now);
        const int status = transfer(connection, discard, 1, remaining, false, nullptr, 0);
        if (status == JSTI_AUTOMATION_PIPE_CLOSED) return JSTI_AUTOMATION_PIPE_OK;
        if (status != JSTI_AUTOMATION_PIPE_OK) return status;
    }
}

int jsti_automation_pipe_security(JSTIAutomationPipeConnection *connection, char *sddl, size_t capacity,
                                  size_t *required, char *error, size_t errorCapacity) {
    if (!connection || connection->pipe == INVALID_HANDLE_VALUE) {
        return fail(JSTI_AUTOMATION_PIPE_CANCELLED, "The automation connection is closed.", error, errorCapacity);
    }
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const DWORD code = GetSecurityInfo(connection->pipe, SE_KERNEL_OBJECT,
                                       OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, nullptr, nullptr,
                                       nullptr, nullptr, &descriptor);
    if (code != ERROR_SUCCESS) return systemFail(-1, "Read automation pipe security", code, error, errorCapacity);
    LPWSTR text = nullptr;
    const BOOL converted = ConvertSecurityDescriptorToStringSecurityDescriptorW(
        descriptor, SDDL_REVISION_1, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &text, nullptr);
    LocalFree(descriptor);
    if (!converted) return systemFail(-1, "Format automation pipe security", GetLastError(), error, errorCapacity);
    const std::string value = utf8(text);
    LocalFree(text);
    if (required) *required = value.size() + 1;
    if (!sddl || capacity < value.size() + 1) return sddl ? 2 : 0;
    std::memcpy(sddl, value.c_str(), value.size() + 1);
    return 0;
}

void jsti_automation_pipe_close(JSTIAutomationPipeConnection *connection) {
    if (!connection) return;
    if (const auto listener = connection->listener) {
        std::unique_lock<std::mutex> lock(listener->mutex);
        listener->connections.erase(connection);
        if (connection->pipe != INVALID_HANDLE_VALUE) {
            DisconnectNamedPipe(connection->pipe);
            CloseHandle(connection->pipe);
            connection->pipe = INVALID_HANDLE_VALUE;
        }
        SetEvent(listener->slotEvent.value);
    } else if (connection->pipe != INVALID_HANDLE_VALUE) {
        CloseHandle(connection->pipe);
    }
    delete connection;
}

int jsti_automation_console_write(int stream, const char *text, size_t count) {
    if ((stream != 1 && stream != 2) || (count && !text) || count > 0x7FFFFFFF) return -1;
    const HANDLE output = GetStdHandle(stream == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
    DWORD mode = 0;
    if (!output || output == INVALID_HANDLE_VALUE || !GetConsoleMode(output, &mode)) return 0;
    if (!count) return 1;
    const int size = MultiByteToWideChar(CP_UTF8, 0, text, static_cast<int>(count), nullptr, 0);
    if (size <= 0) return -1;
    std::wstring converted(static_cast<size_t>(size), 0);
    MultiByteToWideChar(CP_UTF8, 0, text, static_cast<int>(count), &converted[0], size);
    size_t written = 0;
    while (written < converted.size()) {
        DWORD chunk = 0;
        const DWORD request = static_cast<DWORD>(std::min<size_t>(converted.size() - written, 8192));
        if (!WriteConsoleW(output, converted.data() + written, request, &chunk, nullptr) || !chunk) return -1;
        written += chunk;
    }
    return 1;
}

// ---- self-test -------------------------------------------------------------

namespace {
struct ServerProbe {
    JSTIAutomationPipeListener *listener = nullptr;
    int accept = -99, read = -99, write = -99, drain = -99;
    uint8_t received[4] = {};
    std::string sddl;
};

DWORD WINAPI serveOnce(void *context) {
    auto &probe = *static_cast<ServerProbe *>(context);
    JSTIAutomationPipeConnection *connection = nullptr;
    probe.accept = jsti_automation_pipe_accept(probe.listener, &connection, nullptr, 0);
    if (probe.accept != JSTI_AUTOMATION_PIPE_OK) return 0;
    probe.read = jsti_automation_pipe_read(connection, probe.received, 4, 5000, nullptr, 0);
    if (probe.read == JSTI_AUTOMATION_PIPE_OK) {
        char sddl[1024] = {};
        size_t required = 0;
        if (jsti_automation_pipe_security(connection, sddl, sizeof(sddl), &required, nullptr, 0) == 0) probe.sddl = sddl;
        const uint8_t reply[4] = {'p', 'o', 'n', 'g'};
        probe.write = jsti_automation_pipe_write(connection, reply, 4, 5000, nullptr, 0);
        probe.drain = jsti_automation_pipe_drain(connection, 5000);
    }
    jsti_automation_pipe_close(connection);
    return 0;
}

// A thread impersonating this user at low integrity, like a sandboxed process.
// Exit code: 1 setup failed, 2 refused at open or write, 3 wrote but got no
// reply, 4 the server answered it.
DWORD WINAPI lowIntegrityClient(void *context) {
    auto *name = static_cast<const char *>(context);
    HANDLE process = nullptr, duplicate = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY, &process)) return 1;
    Handle owned(process);
    if (!DuplicateTokenEx(process, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation, TokenImpersonation, &duplicate)) {
        return 1;
    }
    Handle token(duplicate);
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_MANDATORY_LABEL_AUTHORITY;
    PSID low = nullptr;
    if (!AllocateAndInitializeSid(&authority, 1, SECURITY_MANDATORY_LOW_RID, 0, 0, 0, 0, 0, 0, 0, &low)) return 1;
    TOKEN_MANDATORY_LABEL label{};
    label.Label.Attributes = SE_GROUP_INTEGRITY;
    label.Label.Sid = low;
    const BOOL lowered = SetTokenInformation(duplicate, TokenIntegrityLevel, &label,
                                             static_cast<DWORD>(sizeof(label) + GetLengthSid(low)));
    FreeSid(low);
    if (!lowered || !SetThreadToken(nullptr, duplicate)) return 1;
    JSTIAutomationPipeConnection *connection = nullptr;
    DWORD outcome = 2;
    if (jsti_automation_pipe_connect(name, 2000, &connection, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK) {
        const uint8_t request[4] = {'l', 'o', 'w', '!'};
        if (jsti_automation_pipe_write(connection, request, 4, 2000, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK) {
            outcome = 3;
            uint8_t reply[4] = {};
            if (jsti_automation_pipe_read(connection, reply, 4, 2000, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK) outcome = 4;
        }
        jsti_automation_pipe_close(connection);
    }
    RevertToSelf();
    return outcome;
}

// Compares SIDs rather than SDDL text, which abbreviates well-known accounts
// (SYSTEM is "SY") and may render access masks differently.
bool ownedByUserAlone(const std::string &sddl) {
    DWORD code = 0;
    const std::vector<BYTE> user = processUser(code);
    const std::wstring wide(sddl.begin(), sddl.end());
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (user.empty() || !ConvertStringSecurityDescriptorToSecurityDescriptorW(wide.c_str(), SDDL_REVISION_1,
                                                                               &descriptor, nullptr)) {
        return false;
    }
    std::unique_ptr<void, decltype(&LocalFree)> owned(descriptor, &LocalFree);
    PSID userSid = const_cast<BYTE *>(user.data());
    PSID owner = nullptr;
    BOOL defaulted = FALSE, present = FALSE;
    PACL dacl = nullptr;
    SECURITY_DESCRIPTOR_CONTROL control = 0;
    DWORD revision = 0;
    if (!GetSecurityDescriptorOwner(descriptor, &owner, &defaulted) || !owner || !EqualSid(owner, userSid) ||
        !GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) || !present || !dacl ||
        !GetSecurityDescriptorControl(descriptor, &control, &revision) || !(control & SE_DACL_PROTECTED) ||
        dacl->AceCount != 2) {
        return false;
    }
    BYTE networkBuffer[SECURITY_MAX_SID_SIZE] = {};
    DWORD networkSize = sizeof(networkBuffer);
    if (!CreateWellKnownSid(WinNetworkSid, nullptr, networkBuffer, &networkSize)) return false;
    bool deniesNetwork = false, allowsUser = false;
    for (DWORD index = 0; index < dacl->AceCount; ++index) {
        void *raw = nullptr;
        if (!GetAce(dacl, index, &raw)) return false;
        const auto *header = static_cast<ACE_HEADER *>(raw);
        if (header->AceType == ACCESS_DENIED_ACE_TYPE) {
            auto *ace = static_cast<ACCESS_DENIED_ACE *>(raw);
            deniesNetwork = deniesNetwork || EqualSid(reinterpret_cast<PSID>(&ace->SidStart), networkBuffer);
        } else if (header->AceType == ACCESS_ALLOWED_ACE_TYPE) {
            auto *ace = static_cast<ACCESS_ALLOWED_ACE *>(raw);
            allowsUser = allowsUser || EqualSid(reinterpret_cast<PSID>(&ace->SidStart), userSid);
        } else {
            return false;
        }
    }
    return deniesNetwork && allowsUser;
}

std::string exchangeFailure(const std::string &name, ServerProbe &probe) {
    HANDLE server = CreateThread(nullptr, 0, serveOnce, &probe, 0, nullptr);
    if (!server) return "Could not start the automation self-test server.";
    JSTIAutomationPipeConnection *client = nullptr;
    uint8_t reply[4] = {};
    const uint8_t request[4] = {'p', 'i', 'n', 'g'};
    std::string failure;
    if (jsti_automation_pipe_connect(name.c_str(), 5000, &client, nullptr, 0) != JSTI_AUTOMATION_PIPE_OK ||
        jsti_automation_pipe_write(client, request, 4, 5000, nullptr, 0) != JSTI_AUTOMATION_PIPE_OK ||
        jsti_automation_pipe_read(client, reply, 4, 5000, nullptr, 0) != JSTI_AUTOMATION_PIPE_OK ||
        std::memcmp(reply, "pong", 4) != 0) {
        failure = "The automation pipe did not carry one request and reply.";
    }
    if (client) jsti_automation_pipe_close(client);
    WaitForSingleObject(server, 10000);
    CloseHandle(server);
    if (!failure.empty()) return failure;
    if (probe.read != JSTI_AUTOMATION_PIPE_OK || std::memcmp(probe.received, "ping", 4) != 0 ||
        probe.write != JSTI_AUTOMATION_PIPE_OK || probe.drain != JSTI_AUTOMATION_PIPE_OK) {
        return "The automation server did not read, answer and drain one client.";
    }
    if (!ownedByUserAlone(probe.sddl)) {
        return "The automation pipe's owner or access list is not this user alone: " + probe.sddl;
    }
    return {};
}
} // namespace

int jsti_automation_pipe_self_test(char *error, size_t capacity) {
    char sid[256] = {};
    size_t required = 0;
    if (jsti_automation_user_sid(sid, sizeof(sid), &required, error, capacity) != 0) return -1;
    const std::string leaf = "JustSpeakToIt-selftest-" + std::to_string(GetCurrentProcessId()) + "-" +
        std::to_string(GetTickCount64());
    const std::string name = "\\\\.\\pipe\\" + leaf;
    const char *nonLocal[] = {"\\\\server\\pipe\\speak", "\\\\.\\pipe\\a\\b", "speak", "\\\\.\\pipe\\"};
    for (const char *candidate : nonLocal) {
        JSTIAutomationPipeListener *refused = nullptr;
        JSTIAutomationPipeConnection *remote = nullptr;
        const bool listened = jsti_automation_pipe_listen(candidate, 1, &refused, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK;
        const bool opened = jsti_automation_pipe_connect(candidate, 10, &remote, nullptr, 0) == JSTI_AUTOMATION_PIPE_OK;
        if (refused) jsti_automation_pipe_listener_release(refused);
        if (remote) jsti_automation_pipe_close(remote);
        if (listened || opened) {
            return fail(-1, "The automation pipe accepted a name outside this computer's pipe namespace.", error,
                        capacity);
        }
    }
    JSTIAutomationPipeConnection *missing = nullptr;
    if (jsti_automation_pipe_connect(name.c_str(), 10, &missing, nullptr, 0) != JSTI_AUTOMATION_PIPE_NOT_FOUND) {
        if (missing) jsti_automation_pipe_close(missing);
        return fail(-1, "Connecting to a missing automation pipe was not reported as not running.", error, capacity);
    }
    JSTIAutomationPipeListener *listener = nullptr;
    if (jsti_automation_pipe_listen(name.c_str(), 2, &listener, error, capacity) != JSTI_AUTOMATION_PIPE_OK) return -1;
    std::string failure;
    JSTIAutomationPipeListener *second = nullptr;
    if (jsti_automation_pipe_listen(name.c_str(), 2, &second, nullptr, 0) != JSTI_AUTOMATION_PIPE_IN_USE) {
        failure = "A second listener was allowed on an owned automation pipe.";
    }
    if (second) jsti_automation_pipe_listener_release(second);
    ServerProbe probe;
    probe.listener = listener;
    if (failure.empty()) failure = exchangeFailure(name, probe);
    if (failure.empty()) {
        const std::wstring redirected = L"\\\\localhost\\pipe\\" + std::wstring(leaf.begin(), leaf.end());
        HANDLE through = CreateFileW(redirected.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                     SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
        if (through != INVALID_HANDLE_VALUE) {
            CloseHandle(through);
            failure = "The automation pipe accepted a client through the network redirector.";
        }
    }
    if (failure.empty()) {
        ServerProbe lowProbe;
        lowProbe.listener = listener;
        HANDLE lowServer = CreateThread(nullptr, 0, serveOnce, &lowProbe, 0, nullptr);
        HANDLE low = CreateThread(nullptr, 0, lowIntegrityClient, const_cast<char *>(name.c_str()), 0, nullptr);
        DWORD outcome = 1;
        if (low) {
            WaitForSingleObject(low, 10000);
            GetExitCodeThread(low, &outcome);
            CloseHandle(low);
        }
        // Unblocks the server when the low-integrity client never connected.
        jsti_automation_pipe_stop(listener, 5000);
        if (lowServer) {
            WaitForSingleObject(lowServer, 10000);
            CloseHandle(lowServer);
        }
        if (outcome == 1) failure = "Could not create the low-integrity automation client.";
        else if (outcome == 4 || (outcome == 3 && lowProbe.read != JSTI_AUTOMATION_PIPE_UNTRUSTED)) {
            failure = "The automation pipe served a low-integrity client.";
        }
    }
    jsti_automation_pipe_listener_release(listener);
    if (!failure.empty()) return fail(-1, failure, error, capacity);
    if (error && capacity) error[0] = 0;
    return 0;
}
