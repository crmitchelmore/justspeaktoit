#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <winhttp.h>
#include <mutex>
#include <vector>

// Blocking WinHTTP requests for CloudKit Web Services. One request object runs
// one exchange at a time on the caller's worker thread; cancel closes the
// native handles from any thread, which makes the blocked call return.

struct JSTIHTTPRequest {
    std::mutex mutex;
    HINTERNET session = nullptr, connection = nullptr, request = nullptr;
    bool cancelled = false;
    std::vector<uint8_t> body;
    std::string headers;

    void closeHandles() {
        if (request) { WinHttpCloseHandle(request); request = nullptr; }
        if (connection) { WinHttpCloseHandle(connection); connection = nullptr; }
        if (session) { WinHttpCloseHandle(session); session = nullptr; }
    }
};

namespace {
enum Result { ok = 0, cancelled = 1, tooLarge = 2, timedOut = 3, transient = 4, failed = -1 };

bool isLoopbackHost(const std::wstring &host) {
    return host == L"127.0.0.1" || host == L"localhost" || host == L"[::1]" || host == L"::1";
}

int classify(DWORD code) {
    switch (code) {
    case ERROR_WINHTTP_TIMEOUT: return timedOut;
    case ERROR_WINHTTP_OPERATION_CANCELLED: return cancelled;
    case ERROR_WINHTTP_CANNOT_CONNECT: case ERROR_WINHTTP_CONNECTION_ERROR:
    case ERROR_WINHTTP_NAME_NOT_RESOLVED: case ERROR_WINHTTP_RESEND_REQUEST:
        return transient;
    default: return failed;
    }
}

struct Failure {
    int result;
    std::string message;
};

Failure nativeFailure(const char *operation, DWORD code = GetLastError()) {
    return Failure{classify(code), jsti::systemError(operation, code)};
}
} // namespace

JSTIHTTPRequest *jsti_http_request_create(void) {
    try { return new JSTIHTTPRequest(); } catch (...) { return nullptr; }
}

void jsti_http_request_cancel(JSTIHTTPRequest *request) {
    if (!request) return;
    std::lock_guard<std::mutex> lock(request->mutex);
    request->cancelled = true;
    request->closeHandles();
}

void jsti_http_request_destroy(JSTIHTTPRequest *request) {
    if (!request) return;
    {
        std::lock_guard<std::mutex> lock(request->mutex);
        request->closeHandles();
    }
    delete request;
}

const uint8_t *jsti_http_request_body(const JSTIHTTPRequest *request, size_t *count) {
    if (count) *count = request ? request->body.size() : 0;
    return request && !request->body.empty() ? request->body.data() : nullptr;
}

const char *jsti_http_request_headers(const JSTIHTTPRequest *request) {
    return request ? request->headers.c_str() : "";
}

namespace {
// Opens handles under the lock so a concurrent cancel either sees them or
// has already marked the request cancelled.
HINTERNET adopt(JSTIHTTPRequest &state, HINTERNET &slot, HINTERNET created, const char *operation) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.cancelled) {
        if (created) WinHttpCloseHandle(created);
        throw Failure{cancelled, "Cancelled."};
    }
    if (!created) throw nativeFailure(operation);
    slot = created;
    return created;
}

void checkCancelled(JSTIHTTPRequest &state) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.cancelled) throw Failure{cancelled, "Cancelled."};
}

void call(JSTIHTTPRequest &state, BOOL result, const char *operation) {
    if (result) return;
    const DWORD code = GetLastError();
    checkCancelled(state);
    throw nativeFailure(operation, code);
}

void exchange(JSTIHTTPRequest &state, const char *method, const char *url, const char *headers,
              const uint8_t *body, size_t bodyCount, size_t limit, int timeout, int &status) {
    std::wstring wideURL, wideMethod, wideHeaders;
    if (!jsti::wide(url, wideURL) || !jsti::wide(method, wideMethod) || wideMethod.empty() ||
        (headers && !jsti::wide(headers, wideHeaders)) || bodyCount > MAXDWORD) {
        throw Failure{failed, "The request could not be prepared."};
    }
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength = 1;
    parts.dwUserNameLength = parts.dwPasswordLength = 1;
    if (!WinHttpCrackUrl(wideURL.c_str(), 0, 0, &parts)) throw Failure{failed, "The request address is invalid."};
    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    const bool secure = parts.nScheme == INTERNET_SCHEME_HTTPS;
    if (parts.dwUserNameLength || parts.dwPasswordLength || host.empty() ||
        (!secure && !(parts.nScheme == INTERNET_SCHEME_HTTP && isLoopbackHost(host)))) {
        throw Failure{failed, "Only HTTPS requests are allowed."};
    }
    std::wstring target(parts.lpszUrlPath, parts.dwUrlPathLength);
    target.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    if (target.empty()) target = L"/";

    HINTERNET session = adopt(state, state.session,
        WinHttpOpen(L"JustSpeakToIt/Windows", secure ? WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY : WINHTTP_ACCESS_TYPE_NO_PROXY,
                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0), "Opening WinHTTP");
    const int wait = timeout > 0 ? timeout : 60000;
    call(state, WinHttpSetTimeouts(session, wait, wait, wait, wait), "Setting WinHTTP timeouts");
    HINTERNET connection = adopt(state, state.connection,
        WinHttpConnect(session, host.c_str(), parts.nPort, 0), "Connecting");
    HINTERNET request = adopt(state, state.request,
        WinHttpOpenRequest(connection, wideMethod.c_str(), target.c_str(), nullptr, WINHTTP_NO_REFERER,
                           WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0), "Opening the request");
    DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
    call(state, WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)),
         "Configuring the request");
    call(state, WinHttpSendRequest(request,
        wideHeaders.empty() ? WINHTTP_NO_ADDITIONAL_HEADERS : wideHeaders.c_str(),
        wideHeaders.empty() ? 0 : static_cast<DWORD>(-1L),
        bodyCount ? const_cast<uint8_t *>(body) : WINHTTP_NO_REQUEST_DATA, static_cast<DWORD>(bodyCount),
        static_cast<DWORD>(bodyCount), 0), "Sending the request");
    call(state, WinHttpReceiveResponse(request, nullptr), "Receiving the response");

    DWORD code = 0, size = sizeof(code);
    call(state, WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                    WINHTTP_HEADER_NAME_BY_INDEX, &code, &size, WINHTTP_NO_HEADER_INDEX),
         "Reading the status");
    status = static_cast<int>(code);
    DWORD headerBytes = 0;
    WinHttpQueryHeaders(request, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
                        WINHTTP_NO_OUTPUT_BUFFER, &headerBytes, WINHTTP_NO_HEADER_INDEX);
    if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && headerBytes) {
        std::wstring raw(headerBytes / sizeof(wchar_t) + 1, L'\0');
        if (WinHttpQueryHeaders(request, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX,
                                &raw[0], &headerBytes, WINHTTP_NO_HEADER_INDEX)) {
            raw.resize(headerBytes / sizeof(wchar_t));
            state.headers = jsti::utf8(raw);
        }
    }
    for (;;) {
        DWORD available = 0;
        call(state, WinHttpQueryDataAvailable(request, &available), "Reading the response");
        if (!available) break;
        if (state.body.size() + available > limit) throw Failure{tooLarge, "The response is too large."};
        const size_t offset = state.body.size();
        state.body.resize(offset + available);
        DWORD read = 0;
        call(state, WinHttpReadData(request, state.body.data() + offset, available, &read), "Reading the response");
        state.body.resize(offset + read);
        if (!read) break;
    }
}
} // namespace

int jsti_http_request_perform(JSTIHTTPRequest *request, const char *method, const char *url,
                              const char *headers, const uint8_t *body, size_t bodyCount,
                              size_t responseLimit, int timeout, int *status,
                              char *error, size_t errorCapacity) {
    if (!request || !method || !url || !status || (!body && bodyCount)) {
        jsti::fail("Invalid HTTP request.", error, errorCapacity);
        return failed;
    }
    *status = 0;
    request->body.clear();
    request->headers.clear();
    int result = ok;
    try {
        exchange(*request, method, url, headers, body, bodyCount, responseLimit, timeout, *status);
    } catch (const Failure &failure) {
        result = failure.result;
        jsti::fail(failure.message, error, errorCapacity);
    } catch (const std::exception &) {
        result = failed;
        jsti::fail("The request ran out of memory.", error, errorCapacity);
    }
    {
        std::lock_guard<std::mutex> lock(request->mutex);
        if (request->cancelled && result != ok) result = cancelled;
        request->closeHandles();
    }
    if (result != ok) request->body.clear();
    return result;
}
