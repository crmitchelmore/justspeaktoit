#include "CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <winhttp.h>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace {
constexpr size_t messageLimit = 4 * 1024 * 1024;
constexpr DWORD callbackFlags = WINHTTP_CALLBACK_FLAG_SENDREQUEST_COMPLETE |
    WINHTTP_CALLBACK_FLAG_HEADERS_AVAILABLE | WINHTTP_CALLBACK_FLAG_READ_COMPLETE |
    WINHTTP_CALLBACK_FLAG_WRITE_COMPLETE | WINHTTP_CALLBACK_FLAG_REQUEST_ERROR |
    WINHTTP_CALLBACK_FLAG_HANDLES | WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE;

struct NativeFailure { DWORD code; const char *operation; DWORD httpStatus = 0; };

bool validUTF8(const uint8_t *bytes, size_t count) {
    return !count || MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        reinterpret_cast<const char *>(bytes), static_cast<int>(count), nullptr, 0) != 0;
}

bool tokenCharacter(wchar_t value) {
    return (value >= L'a' && value <= L'z') || (value >= L'A' && value <= L'Z') ||
        (value >= L'0' && value <= L'9') || std::wcschr(L"!#$%&'*+-.^_`|~", value);
}

std::wstring lowerASCII(std::wstring text) {
    for (auto &value : text) if (value >= L'A' && value <= L'Z') value += L'a' - L'A';
    return text;
}
} // namespace

struct JSTIWebSocket {
    std::wstring host, resource, headers;
    INTERNET_PORT port = 0;
    bool secure = true;
    JSTIWebSocketCallback callback = nullptr;
    void *context = nullptr;
    std::atomic<bool> cancelled{false};
    std::atomic<DWORD> workerID{0};

    // Calls/close are serialized separately from the callback state. WinHTTP
    // may deliver a completion reentrantly from an initiating API call.
    std::mutex calls;
    HINTERNET session = nullptr, connection = nullptr, request = nullptr, socket = nullptr;
    std::mutex mutex;
    std::condition_variable changed;
    std::thread worker;
    bool started = false, open = false;
    unsigned trackedHandles = 0;
    bool requestSent = false, responseReady = false, readReady = false, writeReady = false, closeReady = false;
    DWORD nativeError = 0;
    WINHTTP_WEB_SOCKET_STATUS readResult = {};
    std::array<uint8_t, 64 * 1024> readBuffer{};
    std::vector<uint8_t> peerReason;
    std::vector<uint8_t> sending;
    bool sendPending = false, sendStarted = false, sendText = false;

    ~JSTIWebSocket() {
        if (!headers.empty()) SecureZeroMemory(&headers[0], headers.size() * sizeof(wchar_t));
    }

    void emit(int event, const uint8_t *bytes = nullptr, size_t count = 0, int code = 0) {
        callback(event, bytes, count, code, context);
    }

    void emitError(const NativeFailure &failure) {
        char text[256] = {};
        if (failure.httpStatus) {
            std::snprintf(text, sizeof(text), "WebSocket upgrade returned HTTP %lu.",
                          static_cast<unsigned long>(failure.httpStatus));
        } else {
            std::snprintf(text, sizeof(text), "%s failed (Windows error %lu).", failure.operation,
                          static_cast<unsigned long>(failure.code));
        }
        emit(JSTI_WEBSOCKET_ERROR, reinterpret_cast<const uint8_t *>(text), std::strlen(text),
             static_cast<int>(failure.code));
    }

    static void CALLBACK status(HINTERNET, DWORD_PTR context, DWORD event, void *information, DWORD size) {
        if (!context) return;
        auto &self = *reinterpret_cast<JSTIWebSocket *>(context);
        std::lock_guard<std::mutex> lock(self.mutex);
        switch (event) {
        case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE: self.requestSent = true; break;
        case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE: self.responseReady = true; break;
        case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
            if (!information || size != sizeof(WINHTTP_WEB_SOCKET_STATUS)) {
                self.nativeError = ERROR_INVALID_DATA;
            } else {
                self.readResult = *static_cast<WINHTTP_WEB_SOCKET_STATUS *>(information);
                self.readReady = true;
            }
            break;
        case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE: self.writeReady = true; break;
        case WINHTTP_CALLBACK_STATUS_CLOSE_COMPLETE: self.closeReady = true; break;
        case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
            if (!self.nativeError) self.nativeError = information && size >= sizeof(WINHTTP_ASYNC_RESULT)
                ? static_cast<WINHTTP_ASYNC_RESULT *>(information)->dwError : ERROR_WINHTTP_INTERNAL_ERROR;
            break;
        case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
            if (self.trackedHandles) --self.trackedHandles;
            break;
        default: break;
        }
        // Notify while locked; releasing this lock is the last access to self.
        // HANDLE_CLOSING is the final callback for each tracked native handle.
        self.changed.notify_all();
    }

    void checkCancellation() const {
        if (cancelled.load()) throw NativeFailure{ERROR_OPERATION_ABORTED, "WebSocket cancellation"};
    }

    void checkAsync(BOOL result, const char *operation) {
        if (result) return;
        const DWORD code = GetLastError();
        if (code != ERROR_IO_PENDING) throw NativeFailure{code, operation};
    }

    void waitHandshake(bool JSTIWebSocket::*flag) {
        std::unique_lock<std::mutex> lock(mutex);
        if (!changed.wait_for(lock, std::chrono::seconds(30), [&] {
            return this->*flag || nativeError || cancelled.load();
        })) throw NativeFailure{ERROR_TIMEOUT, "WebSocket handshake"};
        checkCancellation();
        if (nativeError) throw NativeFailure{nativeError, "WebSocket handshake"};
    }

    void handshake() {
        {
            std::lock_guard<std::mutex> guard(calls);
            checkCancellation();
            session = WinHttpOpen(L"JustSpeakToIt/Windows", secure ? WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :
                                  WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS,
                                  WINHTTP_FLAG_ASYNC);
            if (!session) throw NativeFailure{GetLastError(), "Create WinHTTP session"};
            if (!WinHttpSetTimeouts(session, 10000, 10000, 15000, 15000)) {
                throw NativeFailure{GetLastError(), "Configure WinHTTP timeouts"};
            }
            connection = WinHttpConnect(session, host.c_str(), port, 0);
            if (!connection) throw NativeFailure{GetLastError(), "Create WebSocket connection"};
            request = WinHttpOpenRequest(connection, L"GET", resource.c_str(), nullptr, WINHTTP_NO_REFERER,
                                          WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0);
            if (!request) throw NativeFailure{GetLastError(), "Create WebSocket request"};
            const DWORD_PTR pointer = reinterpret_cast<DWORD_PTR>(this);
            if (!WinHttpSetOption(request, WINHTTP_OPTION_CONTEXT_VALUE,
                                   const_cast<DWORD_PTR *>(&pointer), sizeof(pointer))) {
                throw NativeFailure{GetLastError(), "Configure WebSocket callback context"};
            }
            if (WinHttpSetStatusCallback(request, status, callbackFlags, 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
                throw NativeFailure{GetLastError(), "Configure WebSocket callback"};
            }
            { std::lock_guard<std::mutex> lock(mutex); ++trackedHandles; }
            DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
            if (!WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)) ||
                !WinHttpSetOption(request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nullptr, 0)) {
                throw NativeFailure{GetLastError(), "Configure WebSocket upgrade"};
            }
            checkAsync(WinHttpSendRequest(request, headers.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : headers.c_str(),
                                           static_cast<DWORD>(headers.size()), WINHTTP_NO_REQUEST_DATA, 0, 0, pointer),
                        "Send WebSocket upgrade");
        }
        waitHandshake(&JSTIWebSocket::requestSent);
        {
            std::lock_guard<std::mutex> guard(calls);
            checkCancellation();
            checkAsync(WinHttpReceiveResponse(request, nullptr), "Receive WebSocket upgrade");
        }
        waitHandshake(&JSTIWebSocket::responseReady);
        {
            std::lock_guard<std::mutex> guard(calls);
            checkCancellation();
            DWORD statusCode = 0, size = sizeof(statusCode);
            if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                      WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &size, WINHTTP_NO_HEADER_INDEX)) {
                throw NativeFailure{GetLastError(), "Read WebSocket upgrade status"};
            }
            if (statusCode != HTTP_STATUS_SWITCH_PROTOCOLS) {
                throw NativeFailure{ERROR_WINHTTP_INVALID_SERVER_RESPONSE, "WebSocket upgrade", statusCode};
            }
            // The WebSocket inherits the request callback; its explicit context
            // guarantees a final HANDLE_CLOSING notification on cancellation.
            { std::lock_guard<std::mutex> lock(mutex); ++trackedHandles; }
            socket = WinHttpWebSocketCompleteUpgrade(request, reinterpret_cast<DWORD_PTR>(this));
            if (!socket) {
                const DWORD code = GetLastError();
                { std::lock_guard<std::mutex> lock(mutex); --trackedHandles; }
                throw NativeFailure{code, "Complete WebSocket upgrade"};
            }
            if (WinHttpSetStatusCallback(socket, status, callbackFlags, 0) == WINHTTP_INVALID_STATUS_CALLBACK) {
                throw NativeFailure{GetLastError(), "Configure upgraded WebSocket callback"};
            }
            closeHandle(request);
            if (!headers.empty()) SecureZeroMemory(&headers[0], headers.size() * sizeof(wchar_t));
            headers.clear();
            DWORD closeTimeout = 2000;
            if (!WinHttpSetOption(socket, WINHTTP_OPTION_WEB_SOCKET_CLOSE_TIMEOUT, &closeTimeout, sizeof(closeTimeout))) {
                throw NativeFailure{GetLastError(), "Configure WebSocket close timeout"};
            }
        }
        {
            std::lock_guard<std::mutex> lock(mutex);
            checkCancellation();
            open = true;
        }
        emit(JSTI_WEBSOCKET_OPEN);
    }

    void closeHandle(HINTERNET &handle) {
        if (!handle) return;
        if (WinHttpCloseHandle(handle)) handle = nullptr;
        else {
            const DWORD code = GetLastError();
            std::lock_guard<std::mutex> lock(mutex);
            if (!nativeError) nativeError = code;
            changed.notify_all();
        }
    }

    void closeHandles() {
        std::lock_guard<std::mutex> guard(calls);
        closeHandle(socket);
        closeHandle(request);
        closeHandle(connection);
        closeHandle(session);
    }

    void beginReceive() {
        std::lock_guard<std::mutex> guard(calls);
        checkCancellation();
        const DWORD code = WinHttpWebSocketReceive(socket, readBuffer.data(), static_cast<DWORD>(readBuffer.size()),
                                                   nullptr, nullptr);
        if (code != NO_ERROR && code != ERROR_IO_PENDING) throw NativeFailure{code, "Receive WebSocket data"};
    }

    void beginSend() {
        std::lock_guard<std::mutex> guard(calls);
        checkCancellation();
        const DWORD code = WinHttpWebSocketSend(socket, sendText ? WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE :
                                                 WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE,
                                                 sending.empty() ? nullptr : sending.data(),
                                                 static_cast<DWORD>(sending.size()));
        if (code != NO_ERROR && code != ERROR_IO_PENDING) throw NativeFailure{code, "Send WebSocket data"};
    }

    void finishSend(DWORD code, bool releaseBuffer = true) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!sendPending) return;
            sendPending = false;
            sendStarted = false;
            writeReady = false;
            if (releaseBuffer) sending.clear();
        }
        emit(JSTI_WEBSOCKET_SEND_COMPLETE, nullptr, 0, static_cast<int>(code));
    }

    USHORT finishPeerClose() {
        USHORT code = WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS;
        bool cancelQueuedSend = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            open = false;
            cancelQueuedSend = sendPending && !sendStarted;
        }
        if (cancelQueuedSend) finishSend(ERROR_OPERATION_ABORTED);
        {
            std::lock_guard<std::mutex> guard(calls);
            checkCancellation();
            uint8_t reason[WINHTTP_WEB_SOCKET_MAX_CLOSE_REASON_LENGTH] = {};
            DWORD size = 0;
            const DWORD result = WinHttpWebSocketQueryCloseStatus(socket, &code, reason, sizeof(reason), &size);
            if (result != NO_ERROR) throw NativeFailure{result, "Read WebSocket close status"};
            if (size > sizeof(reason) || !validUTF8(reason, size)) {
                throw NativeFailure{ERROR_INVALID_DATA, "Validate WebSocket close reason"};
            }
            peerReason.assign(reason, reason + size);
        }
        // Close may not overlap a send. Drain its completion before acknowledging
        // the peer; local cancellation can still abort this short wait.
        {
            std::unique_lock<std::mutex> lock(mutex);
            changed.wait_for(lock, std::chrono::seconds(2), [&] {
                return !sendPending || writeReady || nativeError || cancelled.load();
            });
            checkCancellation();
            if (sendPending && !writeReady) return code;
        }
        finishSend(NO_ERROR);
        {
            std::lock_guard<std::mutex> guard(calls);
            checkCancellation();
            const DWORD result = WinHttpWebSocketClose(socket,
                code == WINHTTP_WEB_SOCKET_EMPTY_CLOSE_STATUS ?
                    static_cast<USHORT>(WINHTTP_WEB_SOCKET_SUCCESS_CLOSE_STATUS) : code,
                nullptr, 0);
            if (result != NO_ERROR && result != ERROR_IO_PENDING) return code;
        }
        {
            std::unique_lock<std::mutex> lock(mutex);
            changed.wait_for(lock, std::chrono::seconds(2), [&] {
                return closeReady || nativeError || cancelled.load();
            });
        }
        return code;
    }

    USHORT stream() {
        std::vector<uint8_t> assembled;
        int messageKind = 0;
        beginReceive();
        while (true) {
            bool completeSend = false, startSend = false, completeRead = false;
            WINHTTP_WEB_SOCKET_STATUS received = {};
            {
                std::unique_lock<std::mutex> lock(mutex);
                changed.wait(lock, [&] {
                    return cancelled.load() || nativeError || writeReady || readReady ||
                        (sendPending && !sendStarted);
                });
                checkCancellation();
                if (nativeError) throw NativeFailure{nativeError, "WebSocket operation"};
                completeSend = writeReady;
                if (readReady) { completeRead = true; received = readResult; readReady = false; }
                if (sendPending && !sendStarted &&
                    !(completeRead && received.eBufferType == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE)) {
                    startSend = true;
                    sendStarted = true;
                }
            }
            if (completeSend) finishSend(NO_ERROR);
            if (startSend) beginSend();
            if (!completeRead) continue;
            if (received.dwBytesTransferred > readBuffer.size()) {
                throw NativeFailure{ERROR_INVALID_DATA, "Validate WebSocket receive length"};
            }
            if (received.eBufferType == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) return finishPeerClose();
            const bool text = received.eBufferType == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE ||
                received.eBufferType == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
            const bool binary = received.eBufferType == WINHTTP_WEB_SOCKET_BINARY_FRAGMENT_BUFFER_TYPE ||
                received.eBufferType == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;
            if ((!text && !binary) || (messageKind && messageKind != (text ? 1 : 2))) {
                throw NativeFailure{ERROR_INVALID_DATA, "Validate WebSocket fragment type"};
            }
            messageKind = text ? 1 : 2;
            if (received.dwBytesTransferred > messageLimit - assembled.size()) {
                throw NativeFailure{ERROR_BUFFER_OVERFLOW, "WebSocket message exceeds 4 MiB"};
            }
            const size_t required = assembled.size() + received.dwBytesTransferred;
            if (required > assembled.capacity()) {
                assembled.reserve(std::min(messageLimit, std::max(required,
                    std::max(readBuffer.size(), assembled.capacity() * 2))));
            }
            assembled.insert(assembled.end(), readBuffer.begin(), readBuffer.begin() + received.dwBytesTransferred);
            const bool final = received.eBufferType == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE ||
                received.eBufferType == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE;
            if (final) {
                if (text && !validUTF8(assembled.data(), assembled.size())) {
                    throw NativeFailure{ERROR_NO_UNICODE_TRANSLATION, "Validate WebSocket UTF-8"};
                }
                emit(text ? JSTI_WEBSOCKET_TEXT : JSTI_WEBSOCKET_BINARY, assembled.data(), assembled.size());
                assembled.clear();
                messageKind = 0;
            }
            beginReceive();
        }
    }

    bool waitForHandleDrain() {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [&] { return trackedHandles == 0; });
    }

    void run() noexcept {
        workerID.store(GetCurrentThreadId());
        USHORT closeCode = WINHTTP_WEB_SOCKET_ABORTED_CLOSE_STATUS;
        DWORD failureCode = ERROR_OPERATION_ABORTED;
        try {
            handshake();
            closeCode = stream();
        } catch (const NativeFailure &failure) {
            failureCode = failure.code;
            if (!cancelled.load()) emitError(failure);
        } catch (const std::exception &) {
            failureCode = ERROR_NOT_ENOUGH_MEMORY;
            if (!cancelled.load()) emitError({failureCode, "Allocate WebSocket state"});
        }
        if (cancelled.load()) {
            closeCode = WINHTTP_WEB_SOCKET_ENDPOINT_TERMINATED_CLOSE_STATUS;
            peerReason.clear();
        }
        cancelled.store(true);
        { std::lock_guard<std::mutex> lock(mutex); open = false; }
        closeHandles();
        if (waitForHandleDrain()) {
            bool completed = false;
            { std::lock_guard<std::mutex> lock(mutex); completed = writeReady; }
            finishSend(completed ? NO_ERROR : failureCode);
        } else {
            // Keep buffers and callback context alive. destroy reports this
            // failure and can be retried; an in-flight native buffer is never freed.
            emitError({ERROR_TIMEOUT, "Drain WebSocket callbacks"});
            finishSend(ERROR_TIMEOUT, false);
        }
        emit(JSTI_WEBSOCKET_CLOSED, peerReason.data(), peerReason.size(), closeCode);
        workerID.store(0);
    }
};

namespace {
bool configure(JSTIWebSocket &socket, const char *url, const char *const *names,
               const char *const *values, size_t count, std::string &error) {
    std::wstring address;
    if (!jsti::wide(url, address) || address.size() > 32768 || address.find(L'#') != std::wstring::npos) {
        error = "WebSocket URL is invalid.";
        return false;
    }
    if (address.size() >= 6 && lowerASCII(address.substr(0, 6)) == L"wss://") {
        socket.secure = true;
        address.replace(0, 3, L"https");
    } else if (address.size() >= 5 && lowerASCII(address.substr(0, 5)) == L"ws://") {
        socket.secure = false;
        address.replace(0, 2, L"http");
    } else {
        error = "WebSocket URL must use wss, or ws for a local probe.";
        return false;
    }
    URL_COMPONENTS parts = {};
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength =
        parts.dwUserNameLength = parts.dwPasswordLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(address.c_str(), static_cast<DWORD>(address.size()), 0, &parts) ||
        !parts.dwHostNameLength || parts.dwUserNameLength || parts.dwPasswordLength) {
        error = "WebSocket URL is invalid or contains embedded credentials.";
        return false;
    }
    const size_t authorityStart = address.find(L"://") + 3;
    const size_t authorityEnd = address.find_first_of(L"/?", authorityStart);
    if (address.substr(authorityStart, authorityEnd - authorityStart).find(L'@') != std::wstring::npos) {
        error = "WebSocket URL must not contain credentials.";
        return false;
    }
    socket.host.assign(parts.lpszHostName, parts.dwHostNameLength);
    const std::wstring host = lowerASCII(socket.host);
    if (!socket.secure && host != L"localhost" && host != L"127.0.0.1" && host != L"::1" && host != L"[::1]") {
        error = "Unencrypted WebSockets are permitted only for loopback probes.";
        return false;
    }
    socket.port = parts.nPort;
    if (parts.dwUrlPathLength) socket.resource.assign(parts.lpszUrlPath, parts.dwUrlPathLength);
    if (socket.resource.empty()) socket.resource = L"/";
    if (parts.dwExtraInfoLength) socket.resource.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    if (count > 64 || (count && (!names || !values))) {
        error = "WebSocket headers exceed the supported limit.";
        return false;
    }
    std::vector<std::wstring> existing;
    for (size_t index = 0; index < count; ++index) {
        std::wstring name, value;
        if (!jsti::wide(names[index], name) || !jsti::wide(values[index], value) || name.empty() || name.size() > 256 ||
            value.size() > 16384 || !std::all_of(name.begin(), name.end(), tokenCharacter) ||
            std::any_of(value.begin(), value.end(), [](wchar_t ch) { return ch == 127 || (ch < 32 && ch != L'\t'); })) {
            error = "WebSocket headers contain invalid characters or exceed the supported limit.";
            return false;
        }
        const std::wstring lower = lowerASCII(name);
        if (lower == L"host" || lower == L"connection" || lower == L"upgrade" || lower == L"sec-websocket-key" ||
            lower == L"sec-websocket-version" || lower == L"sec-websocket-accept" || lower == L"sec-websocket-extensions" ||
            lower == L"content-length" || lower == L"transfer-encoding" ||
            std::find(existing.begin(), existing.end(), lower) != existing.end()) {
            error = "WebSocket headers contain a duplicate or reserved upgrade header.";
            return false;
        }
        existing.push_back(lower);
        socket.headers += name + L": " + value + L"\r\n";
        if (socket.headers.size() > 32768) {
            error = "WebSocket headers exceed 64 KiB.";
            return false;
        }
    }
    return true;
}
} // namespace

JSTIWebSocket *jsti_websocket_create(const char *url, const char *const *names, const char *const *values,
                                     size_t count, JSTIWebSocketCallback callback, void *context,
                                     char *error, size_t capacity) {
    try {
        if (!callback) { jsti::fail("WebSocket callback is required.", error, capacity); return nullptr; }
        auto socket = std::make_unique<JSTIWebSocket>();
        std::string detail;
        if (!configure(*socket, url, names, values, count, detail)) {
            jsti::fail(detail, error, capacity);
            return nullptr;
        }
        socket->callback = callback;
        socket->context = context;
        if (error && capacity) error[0] = 0;
        return socket.release();
    } catch (const std::exception &) {
        jsti::fail("Could not allocate native WebSocket state.", error, capacity);
        return nullptr;
    }
}

int jsti_websocket_start(JSTIWebSocket *socket, char *error, size_t capacity) {
    if (!socket) return jsti::fail("No native WebSocket supplied.", error, capacity);
    try {
        std::lock_guard<std::mutex> lock(socket->mutex);
        if (socket->started || socket->cancelled.load()) {
            return jsti::fail("Native WebSocket was already started or cancelled.", error, capacity);
        }
        socket->worker = std::thread([socket] { socket->run(); });
        socket->started = true;
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Could not start native WebSocket worker.", error, capacity);
    }
}

int jsti_websocket_send(JSTIWebSocket *socket, const uint8_t *bytes, size_t count,
                        int isText, char *error, size_t capacity) {
    if (!socket || (count && !bytes) || count > messageLimit || (isText != 0 && isText != 1)) {
        return jsti::fail("Native WebSocket send is invalid or exceeds 4 MiB.", error, capacity);
    }
    if (isText && !validUTF8(bytes, count)) return jsti::fail("WebSocket text must be valid UTF-8.", error, capacity);
    try {
        std::lock_guard<std::mutex> lock(socket->mutex);
        if (!socket->open || socket->cancelled.load() || socket->sendPending) {
            return jsti::fail("WebSocket is not open, is cancelled, or already has a pending send.", error, capacity);
        }
        if (count) socket->sending.assign(bytes, bytes + count);
        else socket->sending.clear();
        socket->sendPending = true;
        socket->sendStarted = false;
        socket->sendText = isText != 0;
        socket->changed.notify_all();
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (const std::exception &) {
        return jsti::fail("Could not allocate native WebSocket send buffer.", error, capacity);
    }
}

void jsti_websocket_cancel(JSTIWebSocket *socket) {
    if (!socket) return;
    socket->cancelled.store(true);
    socket->changed.notify_all();
    socket->closeHandles();
}

int jsti_websocket_destroy(JSTIWebSocket *socket, char *error, size_t capacity) {
    if (!socket) return 0;
    if (socket->workerID.load() == GetCurrentThreadId()) {
        return jsti::fail("Destroy the WebSocket outside its callback thread.", error, capacity);
    }
    jsti_websocket_cancel(socket);
    if (socket->worker.joinable()) socket->worker.join();
    if (!socket->waitForHandleDrain()) {
        return jsti::fail("WebSocket callbacks have not drained; retain its context and retry destruction.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> guard(socket->calls);
        if (socket->socket || socket->request || socket->connection || socket->session) {
            return jsti::fail("Native WebSocket handles did not close; retain its context and retry destruction.", error, capacity);
        }
    }
    delete socket;
    if (error && capacity) error[0] = 0;
    return 0;
}

int jsti_websocket_self_test(char *error, size_t capacity) {
    auto callback = [](int, const uint8_t *, size_t, int, void *) {};
    char detail[256] = {};
    const char *invalid[] = {"https://example.com", "ws://example.com", "wss://user:secret@example.com/",
                             "wss://example.com/#fragment", "ws://127.0.0.1.evil.example/"};
    for (const char *url : invalid) {
        auto *socket = jsti_websocket_create(url, nullptr, nullptr, 0, callback, nullptr, detail, sizeof(detail));
        if (socket) {
            jsti_websocket_destroy(socket, nullptr, 0);
            return jsti::fail("Native WebSocket accepted an unsafe test URL.", error, capacity);
        }
        if (!detail[0]) return jsti::fail("Native WebSocket omitted its validation error.", error, capacity);
    }
    const char *names[] = {"Authorization"};
    const char *values[] = {"synthetic\r\nInjected: value"};
    auto *invalidHeader = jsti_websocket_create("wss://example.com/", names, values, 1,
                                                callback, nullptr, detail, sizeof(detail));
    if (invalidHeader) {
        jsti_websocket_destroy(invalidHeader, nullptr, 0);
        return jsti::fail("Native WebSocket accepted header injection.", error, capacity);
    }
    auto *valid = jsti_websocket_create("ws://127.0.0.1:12345/probe?q=synthetic", nullptr, nullptr, 0,
                                        callback, nullptr, detail, sizeof(detail));
    if (!valid) return jsti::fail(detail, error, capacity);
    jsti_websocket_cancel(valid);
    const int startResult = jsti_websocket_start(valid, detail, sizeof(detail));
    const int destroyResult = jsti_websocket_destroy(valid, detail, sizeof(detail));
    if (startResult != -1 || destroyResult != 0) {
        return jsti::fail("Native WebSocket cancelled-before-start lifecycle failed.", error, capacity);
    }
    if (error && capacity) error[0] = 0;
    return 0;
}
