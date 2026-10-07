#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "WindowsTextOutputInternal.hpp"
#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// Automatic clipboard output without a captured field. A recording started
// with this window's Record button has no insertion target to carry its
// clipboard-only request, so the request gets its own cancellation and
// lifetime here. The job never looks at focus, never inserts and never sends
// input; it places text exactly as the captured-field clipboard path does.

using namespace jsti::textoutput;

struct JSTIClipboardOutput {
    Environment environment;
    std::mutex mutex;
    bool cancelled = false;
    bool used = false;
};

namespace {
JSTIClipboardOutput *createJob(const Environment &environment) {
    auto job = std::make_unique<JSTIClipboardOutput>();
    job->environment = environment;
    return job.release();
}
} // namespace

JSTIClipboardOutput *jsti_clipboard_output_create(char *error, size_t capacity) {
    try {
        JSTIClipboardOutput *job = createJob(defaultEnvironment());
        if (error && capacity) error[0] = 0;
        return job;
    } catch (...) {
        jsti::fail("Could not allocate the clipboard output.", error, capacity);
        return nullptr;
    }
}

int jsti_clipboard_output_copy(JSTIClipboardOutput *job, const char *text, int *clipboardState,
                               char *error, size_t capacity) {
    if (clipboardState) *clipboardState = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
    if (!job) return jsti::fail("No clipboard output request.", error, capacity);
    try {
        {
            std::lock_guard<std::mutex> lock(job->mutex);
            if (job->cancelled) return jsti::fail("The clipboard output was cancelled.", error, capacity);
            if (job->used) return jsti::fail("This clipboard output was already used.", error, capacity);
            job->used = true;
        }
        std::wstring value;
        if (!jsti::wide(text, value)) return jsti::fail("Clipboard text is not valid UTF-8.", error, capacity);
        if (value.empty()) return jsti::fail("There is no transcript text to copy.", error, capacity);
        std::string reason;
        int state = JSTI_INSERTION_CLIPBOARD_UNTOUCHED;
        // The linearisation point: the clipboard is owned and snapshotted, and
        // nothing has been replaced yet. A cancel ordered before this check
        // prevents the write; one ordered after it cannot undo the write.
        const bool copied = copyTextToClipboard(job->environment, value, [job] {
            std::lock_guard<std::mutex> lock(job->mutex);
            return !job->cancelled;
        }, state, reason);
        if (clipboardState) *clipboardState = state;
        if (!copied) return jsti::fail(reason, error, capacity);
        if (error && capacity) error[0] = 0;
        return 0;
    } catch (...) {
        return jsti::fail("Could not copy the transcript.", error, capacity);
    }
}

void jsti_clipboard_output_cancel(JSTIClipboardOutput *job) {
    if (!job) return;
    std::lock_guard<std::mutex> lock(job->mutex);
    job->cancelled = true;
}

void jsti_clipboard_output_destroy(JSTIClipboardOutput *job) { delete job; }

// ---- self-test -------------------------------------------------------------

namespace {
std::mutex selfTestMutex;
// A registered-range format standing in for another application's rich data.
constexpr UINT customFormat = 0xC123;

// In-memory clipboard with deterministic hooks. Hooks run without the fake's
// lock, like another thread acting while this process owns the clipboard.
struct FakeClipboard final : Clipboard {
    std::mutex mutex;
    std::map<UINT, std::vector<uint8_t>> items;
    std::vector<HGLOBAL> borrowed;
    DWORD sequenceNumber = 1;
    bool isOpen = false;
    int opens = 0;
    bool refuseOpen = false;
    bool failUnicodeSet = false;
    void (*onOpen)(void *) = nullptr;
    void (*onEmpty)(void *) = nullptr;
    void *hookContext = nullptr;

    bool open(HWND) override {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (refuseOpen || isOpen) return false;
            isOpen = true;
            ++opens;
        }
        if (onOpen) onOpen(hookContext);
        return true;
    }
    void close() override {
        std::lock_guard<std::mutex> lock(mutex);
        for (HGLOBAL handle : borrowed) GlobalFree(handle);
        borrowed.clear();
        isOpen = false;
    }
    bool empty() override {
        if (onEmpty) onEmpty(hookContext);
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen) return false;
        items.clear();
        ++sequenceNumber;
        return true;
    }
    UINT next(UINT format) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen || items.empty()) return 0;
        if (!format) return items.begin()->first;
        const auto following = items.upper_bound(format);
        return following == items.end() ? 0 : following->first;
    }
    HANDLE get(UINT format) override {
        std::lock_guard<std::mutex> lock(mutex);
        const auto found = items.find(format);
        if (!isOpen || found == items.end()) return nullptr;
        HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, found->second.size());
        void *destination = handle ? GlobalLock(handle) : nullptr;
        if (!destination) { if (handle) GlobalFree(handle); return nullptr; }
        std::memcpy(destination, found->second.data(), found->second.size());
        GlobalUnlock(handle);
        borrowed.push_back(handle);
        return handle;
    }
    bool set(UINT format, HGLOBAL data) override {
        std::lock_guard<std::mutex> lock(mutex);
        if (!isOpen || !data) return false;
        if (format == CF_UNICODETEXT && failUnicodeSet) { failUnicodeSet = false; return false; }
        const SIZE_T size = GlobalSize(data);
        const void *source = GlobalLock(data);
        if (!source) return false;
        items[format].assign(static_cast<const uint8_t *>(source), static_cast<const uint8_t *>(source) + size);
        GlobalUnlock(data);
        GlobalFree(data);
        ++sequenceNumber;
        return true;
    }
    DWORD sequence() override {
        std::lock_guard<std::mutex> lock(mutex);
        return sequenceNumber;
    }

    // Another application's copy: bypasses open/close.
    void userCopies(const std::wstring &text) {
        std::lock_guard<std::mutex> lock(mutex);
        items.clear();
        const auto *bytes = reinterpret_cast<const uint8_t *>(text.c_str());
        items[CF_UNICODETEXT].assign(bytes, bytes + (text.size() + 1) * sizeof(wchar_t));
        items[customFormat].assign({1, 2, 3});
        ++sequenceNumber;
    }
    std::wstring unicodeText() {
        std::lock_guard<std::mutex> lock(mutex);
        const auto found = items.find(CF_UNICODETEXT);
        if (found == items.end() || found->second.size() < sizeof(wchar_t)) return {};
        std::wstring text(reinterpret_cast<const wchar_t *>(found->second.data()),
                          found->second.size() / sizeof(wchar_t));
        return text.substr(0, text.find(L'\0'));
    }
    bool has(UINT format) {
        std::lock_guard<std::mutex> lock(mutex);
        return items.count(format) != 0;
    }
    bool closed() {
        std::lock_guard<std::mutex> lock(mutex);
        return !isOpen;
    }
};

FakeClipboard *activeClipboard = nullptr;
std::atomic<int> focusOrInputCalls{0};

Clipboard *syntheticClipboard() { return activeClipboard; }
HWND tripForeground() { ++focusOrInputCalls; return nullptr; }
unsigned tripSendPaste(std::string &) { ++focusOrInputCalls; return 0; }
bool tripPreparePaste(std::string &) { ++focusOrInputCalls; return false; }
uint64_t tripFocusRevision() { ++focusOrInputCalls; return 0; }
bool tripCaptureFocus(FocusEvent &) { ++focusOrInputCalls; return false; }

Environment syntheticEnvironment() {
    Environment environment = defaultEnvironment();
    environment.clipboard = &syntheticClipboard;
    environment.foregroundWindow = &tripForeground;
    environment.sendPaste = &tripSendPaste;
    environment.preparePaste = &tripPreparePaste;
    environment.focusRevision = &tripFocusRevision;
    environment.captureFocusEvent = &tripCaptureFocus;
    return environment;
}

struct Job {
    JSTIClipboardOutput *value = createJob(syntheticEnvironment());
    ~Job() { jsti_clipboard_output_destroy(value); }
    Job() = default;
    Job(const Job &) = delete;
    Job &operator=(const Job &) = delete;
};

struct Attempt {
    int status = 0;
    int clipboard = -1;
    std::string error;
};

Attempt copy(JSTIClipboardOutput *job, const char *text) {
    Attempt attempt;
    char message[512]{};
    attempt.status = jsti_clipboard_output_copy(job, text, &attempt.clipboard, message, sizeof(message));
    attempt.error = message;
    return attempt;
}

std::string describe(const char *scenario, const char *problem, const std::string &detail = {}) {
    std::string message = std::string("Clipboard output self-test (") + scenario + "): " + problem;
    if (!detail.empty()) message += " [" + detail + "]";
    return message;
}

void cancelHook(void *context) { jsti_clipboard_output_cancel(static_cast<JSTIClipboardOutput *>(context)); }

struct Gate {
    jsti::Handle entered, proceed;
    Gate() {
        entered.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        proceed.value = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    }
};

void blockInOwnedSection(void *context) {
    auto *gate = static_cast<Gate *>(context);
    SetEvent(gate->entered.value);
    WaitForSingleObject(gate->proceed.value, 10000);
}

std::string checkCopies(FakeClipboard &clipboard) {
    clipboard.userCopies(L"previous clipboard");
    {
        Job job;
        const Attempt attempt = copy(job.value, "Caf\xc3\xa9 \xf0\x9f\x91\x8b transcript");
        if (attempt.status != 0 || attempt.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT ||
            clipboard.unicodeText() != L"Café \U0001F44B transcript" || !clipboard.closed() ||
            clipboard.has(customFormat)) {
            return describe("copy", "the transcript was not left as plain Unicode text", attempt.error);
        }
        // Parity with jsti_insertion_copy_text: a chosen copy is ordinary
        // clipboard content, unlike the transient guarded paste.
        if (clipboard.has(excludeFromHistoryFormat()) || clipboard.has(excludeFromCloudFormat()) ||
            clipboard.has(excludeFromMonitoringFormat())) {
            return describe("copy", "clipboard-only output diverged from the captured-field copy");
        }
        const int opens = clipboard.opens;
        const Attempt second = copy(job.value, "second use");
        if (second.status != -1 || clipboard.opens != opens || clipboard.unicodeText() != L"Café \U0001F44B transcript") {
            return describe("single use", "a used job copied again", second.error);
        }
    }
    clipboard.userCopies(L"previous clipboard");
    {
        Job job;
        const int opens = clipboard.opens;
        jsti_clipboard_output_cancel(job.value);
        const Attempt attempt = copy(job.value, "cancelled before copy");
        if (attempt.status != -1 || clipboard.opens != opens || clipboard.unicodeText() != L"previous clipboard" ||
            attempt.clipboard != JSTI_INSERTION_CLIPBOARD_UNTOUCHED) {
            return describe("cancel before copy", "a cancelled job opened or changed the clipboard", attempt.error);
        }
    }
    {
        Job empty, invalid;
        const int opens = clipboard.opens;
        const Attempt emptyText = copy(empty.value, "");
        const Attempt invalidText = copy(invalid.value, "\xc3\x28");
        const Attempt missing = copy(nullptr, "text");
        if (emptyText.status != -1 || invalidText.status != -1 || missing.status != -1 || clipboard.opens != opens ||
            clipboard.unicodeText() != L"previous clipboard" || emptyText.error.find("no transcript") == std::string::npos ||
            invalidText.error.find("UTF-8") == std::string::npos) {
            return describe("invalid input", "empty, invalid or unowned text reached the clipboard");
        }
    }
    {
        // State is checked before the text, so an empty request is a
        // side-effect-free probe of whether a job was cancelled.
        Job job;
        jsti_clipboard_output_cancel(job.value);
        const Attempt probe = copy(job.value, "");
        if (probe.status != -1 || probe.error.find("cancelled") == std::string::npos) {
            return describe("cancelled probe", "a cancelled job was not reported as cancelled", probe.error);
        }
    }
    return {};
}

std::string checkOwnedSectionCancellation(FakeClipboard &clipboard) {
    clipboard.userCopies(L"previous clipboard");
    {
        // Cancel while this process owns the clipboard, before the check.
        Job job;
        clipboard.onOpen = &cancelHook;
        clipboard.hookContext = job.value;
        const Attempt attempt = copy(job.value, "cancelled while owned");
        clipboard.onOpen = nullptr;
        if (attempt.status != -1 || clipboard.unicodeText() != L"previous clipboard" || !clipboard.has(customFormat) ||
            !clipboard.closed() || attempt.clipboard != JSTI_INSERTION_CLIPBOARD_UNTOUCHED) {
            return describe("cancel while owned", "the clipboard changed after cancellation", attempt.error);
        }
    }
    {
        // A cancel from another thread returns while copy holds the clipboard.
        Job job;
        Gate gate;
        if (!gate.entered.value || !gate.proceed.value) return describe("concurrent cancel", "events unavailable");
        clipboard.onOpen = &blockInOwnedSection;
        clipboard.hookContext = &gate;
        Attempt attempt;
        std::thread worker([&] { attempt = copy(job.value, "cancelled concurrently"); });
        const bool entered = WaitForSingleObject(gate.entered.value, 10000) == WAIT_OBJECT_0;
        const ULONGLONG started = GetTickCount64();
        jsti_clipboard_output_cancel(job.value);
        const bool prompt = GetTickCount64() - started < 1000;
        SetEvent(gate.proceed.value);
        worker.join();
        clipboard.onOpen = nullptr;
        if (!entered || !prompt || attempt.status != -1 || clipboard.unicodeText() != L"previous clipboard" ||
            !clipboard.closed()) {
            return describe("concurrent cancel", "cancel blocked or a late write replaced the clipboard", attempt.error);
        }
    }
    {
        // After the check the write is committed; a late cancel is reported
        // as the copy it could no longer prevent.
        Job job;
        clipboard.onEmpty = &cancelHook;
        clipboard.hookContext = job.value;
        const Attempt attempt = copy(job.value, "committed copy");
        clipboard.onEmpty = nullptr;
        if (attempt.status != 0 || clipboard.unicodeText() != L"committed copy" ||
            attempt.clipboard != JSTI_INSERTION_CLIPBOARD_TRANSCRIPT_LEFT) {
            return describe("cancel after commit", "a committed write was misreported", attempt.error);
        }
    }
    clipboard.hookContext = nullptr;
    return {};
}

std::string checkFailures(FakeClipboard &clipboard) {
    clipboard.userCopies(L"previous clipboard");
    {
        Job job;
        clipboard.failUnicodeSet = true;
        const Attempt attempt = copy(job.value, "failed write");
        if (attempt.status != -1 || attempt.clipboard != JSTI_INSERTION_CLIPBOARD_RESTORED ||
            clipboard.unicodeText() != L"previous clipboard" || !clipboard.has(customFormat) || !clipboard.closed()) {
            return describe("failed write", "the previous clipboard was not restored", attempt.error);
        }
    }
    {
        Job job;
        clipboard.refuseOpen = true;
        const Attempt attempt = copy(job.value, "busy clipboard");
        clipboard.refuseOpen = false;
        if (attempt.status != -1 || attempt.clipboard != JSTI_INSERTION_CLIPBOARD_UNTOUCHED ||
            clipboard.unicodeText() != L"previous clipboard" || attempt.error.empty()) {
            return describe("busy clipboard", "an unavailable clipboard was not reported", attempt.error);
        }
    }
    // Destroying unused and cancelled jobs releases them without clipboard use.
    const int opens = clipboard.opens;
    jsti_clipboard_output_destroy(createJob(syntheticEnvironment()));
    JSTIClipboardOutput *cancelled = createJob(syntheticEnvironment());
    jsti_clipboard_output_cancel(cancelled);
    jsti_clipboard_output_destroy(cancelled);
    jsti_clipboard_output_cancel(nullptr);
    jsti_clipboard_output_destroy(nullptr);
    if (clipboard.opens != opens) return describe("destroy", "destroying a job touched the clipboard");
    return {};
}
} // namespace

int jsti_clipboard_output_self_test(char *error, size_t capacity) {
    std::lock_guard<std::mutex> lock(selfTestMutex);
    try {
        auto clipboard = std::make_unique<FakeClipboard>();
        activeClipboard = clipboard.get();
        focusOrInputCalls = 0;
        std::string failure = checkCopies(*clipboard);
        if (failure.empty()) failure = checkOwnedSectionCancellation(*clipboard);
        if (failure.empty()) failure = checkFailures(*clipboard);
        if (failure.empty() && focusOrInputCalls != 0) {
            failure = describe("isolation", "clipboard output queried focus or prepared input");
        }
        activeClipboard = nullptr;
        if (!failure.empty()) return jsti::fail(failure, error, capacity);
    } catch (const std::exception &) {
        activeClipboard = nullptr;
        return jsti::fail("The clipboard output self-test could not allocate its fixtures.", error, capacity);
    }
    if (error && capacity) error[0] = 0;
    return 0;
}
