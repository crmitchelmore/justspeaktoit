#include "WindowsAutomationPipeInternal.hpp"
#include <aclapi.h>
#include <algorithm>
#include <cstring>

namespace jsti::automation {
namespace {
const wchar_t localPrefix[] = L"\\\\.\\pipe\\";

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
} // namespace

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

} // namespace jsti::automation

using namespace jsti::automation;

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
