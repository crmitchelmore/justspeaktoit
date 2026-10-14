#include "include/WindowsClipboardRead.h"
#include <windows.h>
#include <atomic>
#include <chrono>
#include <climits>
#include <condition_variable>
#include <cstdio>
#include <exception>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace {
struct ReadState {
    size_t maximum;
    std::chrono::milliseconds budget;
    std::mutex mutex;
    std::condition_variable changed;
    std::atomic<bool> cancelled{false};
    bool started = false;
    bool done = false;
    int32_t status = -1;
    std::string text;
    std::string error;
    std::function<int32_t(const std::atomic<bool> &, std::string &, std::string &)> syntheticReader;
    ReadState(size_t maximum, uint32_t timeout) : maximum(maximum), budget(timeout) {}
};

std::atomic<bool> workerActive{false};

void message(char *output, size_t capacity, const char *text) {
    if (output != nullptr && capacity != 0) std::snprintf(output, capacity, "%s", text);
}

struct ClipboardLease {
    bool opened = false;
    bool close() {
        if (!opened) return true;
        if (!CloseClipboard()) return false;
        opened = false;
        return true;
    }
    ~ClipboardLease() { if (opened) CloseClipboard(); }
};

struct LockedText {
    HGLOBAL handle;
    const wchar_t *text;
    explicit LockedText(HGLOBAL handle)
        : handle(handle), text(static_cast<const wchar_t *>(GlobalLock(handle))) {}
    ~LockedText() { if (text != nullptr) GlobalUnlock(handle); }
};

int32_t decodeText(const wchar_t *input, size_t available, size_t maximum,
                  std::string &text, std::string &error) {
    text.clear();
    size_t length = 0;
    while (length < available && length <= maximum && input[length] != L'\0') ++length;
    if (length > maximum) { error = "The clipboard text exceeds the read limit."; return 2; }
    if (length == available) { error = "The clipboard text is not terminated."; return 3; }
    if (length == 0) return 0;
    const int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input,
        static_cast<int>(length), nullptr, 0, nullptr, nullptr);
    if (required == 0) { error = "The clipboard contains invalid UTF-16 text."; return 3; }
    if (static_cast<size_t>(required) > maximum) {
        error = "The clipboard text exceeds the read limit."; return 2;
    }
    text.resize(static_cast<size_t>(required));
    if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input, static_cast<int>(length),
        text.data(), required, nullptr, nullptr) != required) {
        error = "The clipboard text could not be converted to UTF-8."; return 3;
    }
    return 0;
}

int32_t readClipboard(const std::shared_ptr<ReadState> &state, std::string &text, std::string &error) {
    ClipboardLease lease;
    for (int attempt = 0; attempt < 10 && !state->cancelled.load(); ++attempt) {
        if (OpenClipboard(nullptr)) { lease.opened = true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    if (state->cancelled.load()) { error = "The clipboard read was cancelled."; return 5; }
    if (!lease.opened) { error = "The clipboard could not be opened for reading."; return -1; }
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        if (!lease.close()) { error = "The clipboard read could not release its lease."; return -1; }
        return 1;
    }
    if (state->cancelled.load()) { error = "The clipboard read was cancelled."; return 5; }
    // Delayed rendering may block here beyond the caller budget. This worker
    // alone retains/releases the borrowed handle and clipboard lease.
    HGLOBAL handle = GetClipboardData(CF_UNICODETEXT);
    if (state->cancelled.load()) { error = "The clipboard read was cancelled."; return 5; }
    if (handle == nullptr) { error = "The clipboard text could not be retrieved."; return -1; }
    const SIZE_T bytes = GlobalSize(handle);
    if (bytes < sizeof(wchar_t) || bytes % sizeof(wchar_t) != 0) {
        error = "The clipboard contains invalid UTF-16 text."; return 3;
    }
    int32_t status;
    {
        LockedText locked(handle);
        if (locked.text == nullptr) { error = "The clipboard text could not be locked."; return -1; }
        status = decodeText(locked.text, bytes / sizeof(wchar_t), state->maximum, text, error);
    }
    if (!lease.close()) { error = "The clipboard read could not release its lease."; return -1; }
    return status;
}

void worker(const std::shared_ptr<ReadState> &state) {
    std::string text, error;
    int32_t status;
    try {
        status = state->syntheticReader
            ? state->syntheticReader(state->cancelled, text, error)
            : readClipboard(state, text, error);
    } catch (const std::exception &) {
        status = -1;
        error = "The native clipboard reader could not allocate its result.";
    }
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        workerActive.store(false);
        if (!state->done) {
            state->status = status;
            state->text = std::move(text);
            state->error = std::move(error);
            state->done = true;
        }
    }
    state->changed.notify_all();
}
}

struct JSTIWindowsClipboardRead { std::shared_ptr<ReadState> state; };

extern "C" JSTIWindowsClipboardRead *jsti_windows_clipboard_read_create(
    size_t maximum, uint32_t timeout, char *error, size_t capacity) {
    if (maximum == 0 || maximum >= INT_MAX || timeout == 0) {
        message(error, capacity, "Invalid clipboard read bounds."); return nullptr;
    }
    try {
        return new JSTIWindowsClipboardRead{std::make_shared<ReadState>(maximum, timeout)};
    } catch (const std::exception &) {
        message(error, capacity, "The clipboard read request could not be allocated."); return nullptr;
    }
}

extern "C" int32_t jsti_windows_clipboard_read_run(JSTIWindowsClipboardRead *request,
    char *text, size_t textCapacity, char *error, size_t errorCapacity) {
    if (request == nullptr || text == nullptr || textCapacity <= request->state->maximum) {
        message(error, errorCapacity, "Invalid clipboard read output buffer."); return -1;
    }
    text[0] = '\0';
    auto state = request->state;
    std::unique_lock<std::mutex> lock(state->mutex);
    if (state->started) {
        message(error, errorCapacity, "The clipboard request has already run."); return -1;
    }
    state->started = true;
    if (!state->done) {
        bool expected = false;
        if (!workerActive.compare_exchange_strong(expected, true)) {
            message(error, errorCapacity, "A previous clipboard read is still cleaning up."); return 7;
        }
        try {
            std::thread(worker, state).detach();
        } catch (const std::exception &) {
            workerActive.store(false);
            message(error, errorCapacity, "The native clipboard reader could not start."); return -1;
        }
        if (!state->changed.wait_for(lock, state->budget, [&] { return state->done; })) {
            state->cancelled.store(true);
            state->done = true;
            state->status = 4;
            state->error = "The clipboard did not respond before the read deadline.";
        }
    }
    if (state->status == 0) message(text, textCapacity, state->text.c_str());
    else if (state->status != 1) message(error, errorCapacity, state->error.c_str());
    return state->status;
}

extern "C" void jsti_windows_clipboard_read_cancel(JSTIWindowsClipboardRead *request) {
    if (request == nullptr) return;
    auto state = request->state;
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->cancelled.store(true);
        if (!state->done) {
            state->done = true;
            state->status = 5;
            state->error = "The clipboard read was cancelled.";
        }
    }
    state->changed.notify_all();
}

extern "C" void jsti_windows_clipboard_read_destroy(JSTIWindowsClipboardRead *request) {
    delete request;
}

extern "C" int32_t jsti_windows_clipboard_read_self_test(char *error, size_t capacity) {
    try {
        std::string text, failure;
        const wchar_t invalid[] = {0xd800, 0};
        const wchar_t unterminated[] = {L'a', L'b'};
        const wchar_t emoji[] = {0xd83d, 0xde00, 0};
        if (decodeText(L"", 1, 8, text, failure) != 0 ||
            decodeText(L"SYNTHETIC", 10, 9, text, failure) != 0 || text != "SYNTHETIC" ||
            decodeText(L"SYNTHETIC", 10, 8, text, failure) != 2 ||
            decodeText(invalid, 2, 8, text, failure) != 3 ||
            decodeText(unterminated, 2, 8, text, failure) != 3 ||
            decodeText(emoji, 3, 4, text, failure) != 0 || text.size() != 4 ||
            decodeText(emoji, 3, 3, text, failure) != 2) {
            message(error, capacity, "Synthetic clipboard UTF-16 decoding fixture failed."); return -1;
        }
        char output[33] = {};
        auto request = std::unique_ptr<JSTIWindowsClipboardRead>(
            jsti_windows_clipboard_read_create(32, 10, error, capacity));
        if (!request) return -1;
        jsti_windows_clipboard_read_cancel(request.get());
        if (jsti_windows_clipboard_read_run(request.get(), output, sizeof(output), error, capacity) != 5) {
            message(error, capacity, "Cancelled clipboard request started a reader."); return -1;
        }
        auto released = std::make_shared<std::atomic<bool>>(false);
        struct ReleaseOnExit {
            std::shared_ptr<std::atomic<bool>> flag;
            ~ReleaseOnExit() { flag->store(true); }
        } releaseOnExit{released};
        request.reset(jsti_windows_clipboard_read_create(32, 10, error, capacity));
        if (!request) return -1;
        request->state->syntheticReader = [released](const std::atomic<bool> &, std::string &value, std::string &) {
            while (!released->load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            value = "LATE SYNTHETIC";
            return 0;
        };
        int32_t result = jsti_windows_clipboard_read_run(request.get(), output, sizeof(output), error, capacity);
        request.reset();
        auto second = std::unique_ptr<JSTIWindowsClipboardRead>(
            jsti_windows_clipboard_read_create(32, 10, error, capacity));
        if (!second) { released->store(true); return -1; }
        // Busy admission must not call a backend, even after caller destruction.
        second->state->syntheticReader = [](const std::atomic<bool> &, std::string &, std::string &) { return -1; };
        int32_t busy = jsti_windows_clipboard_read_run(second.get(), output, sizeof(output), error, capacity);
        released->store(true);
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (workerActive.load() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (result != 4 || busy != 7 || output[0] != '\0' || workerActive.load()) {
            message(error, capacity, "Synthetic clipboard deadline/admission/cleanup fixture failed."); return -1;
        }
        auto last = std::unique_ptr<JSTIWindowsClipboardRead>(
            jsti_windows_clipboard_read_create(32, 1000, error, capacity));
        if (!last) return -1;
        last->state->syntheticReader = [](const std::atomic<bool> &, std::string &value, std::string &) {
            value = "SYNTHETIC"; return 0;
        };
        if (jsti_windows_clipboard_read_run(last.get(), output, sizeof(output), error, capacity) != 0 ||
            std::string(output) != "SYNTHETIC") {
            message(error, capacity, "Synthetic clipboard restart fixture failed."); return -1;
        }
        auto entered = std::make_shared<std::atomic<bool>>(false);
        auto releaseCancelled = std::make_shared<std::atomic<bool>>(false);
        ReleaseOnExit cancelRelease{releaseCancelled};
        auto cancelled = std::unique_ptr<JSTIWindowsClipboardRead>(
            jsti_windows_clipboard_read_create(32, 1000, error, capacity));
        if (!cancelled) return -1;
        cancelled->state->syntheticReader = [entered, releaseCancelled](
            const std::atomic<bool> &, std::string &value, std::string &) {
            entered->store(true);
            while (!releaseCancelled->load()) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            value = "UNTRUSTED LATE TEXT";
            return 0;
        };
        std::thread canceller([entered, pointer = cancelled.get()] {
            auto limit = std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
            while (!entered->load() && std::chrono::steady_clock::now() < limit)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            jsti_windows_clipboard_read_cancel(pointer);
        });
        int32_t cancellation = jsti_windows_clipboard_read_run(
            cancelled.get(), output, sizeof(output), error, capacity);
        canceller.join();
        cancelled.reset();
        releaseCancelled->store(true);
        deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (workerActive.load() && std::chrono::steady_clock::now() < deadline)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (cancellation != 5 || output[0] != '\0' || workerActive.load()) {
            message(error, capacity, "Synthetic clipboard in-flight cancellation fixture failed."); return -1;
        }
        return 0;
    } catch (const std::exception &) {
        message(error, capacity, "Synthetic clipboard fixtures could not allocate their state."); return -1;
    }
}
