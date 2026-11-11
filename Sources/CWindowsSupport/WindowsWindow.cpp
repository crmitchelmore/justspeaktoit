// The main window: its shared state, the hands-free session guard and jsti_window_run.
#include "WindowsWindowInternal.hpp"

static_assert(!(JSTI_EVENT_USER_ABSENT >= 100 && JSTI_EVENT_USER_ABSENT <= 109) &&
    !(JSTI_EVENT_USER_ABSENT >= 120 && JSTI_EVENT_USER_ABSENT <= 129),
    "Session absence must not be routed as a comparison action.");
namespace jsti_window {
HMODULE handsFreeWts = nullptr;
using HandsFreeRegister = BOOL (WINAPI *)(HWND, DWORD);
using HandsFreeUnregister = BOOL (WINAPI *)(HWND);
HandsFreeUnregister handsFreeUnregister = nullptr;
std::atomic<bool> handsFreeGuardRegistered{false};
std::atomic<unsigned> handsFreeAbsence{0};

void startHandsFreeGuard(HWND window) {
    handsFreeAbsence = 0;
    handsFreeWts = LoadLibraryExW(L"Wtsapi32.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!handsFreeWts) {
        std::fprintf(stderr, "Hands-free unavailable: native session monitoring could not load.\n");
        return;
    }
    auto subscribe = reinterpret_cast<HandsFreeRegister>(GetProcAddress(handsFreeWts, "WTSRegisterSessionNotification"));
    handsFreeUnregister = reinterpret_cast<HandsFreeUnregister>(GetProcAddress(handsFreeWts, "WTSUnRegisterSessionNotification"));
    handsFreeGuardRegistered = subscribe && handsFreeUnregister && subscribe(window, NOTIFY_FOR_THIS_SESSION);
    if (handsFreeGuardRegistered) {
        using Query = BOOL (WINAPI *)(HANDLE, DWORD, WTS_INFO_CLASS, LPWSTR *, DWORD *);
        using Release = void (WINAPI *)(PVOID);
        auto query = reinterpret_cast<Query>(GetProcAddress(handsFreeWts, "WTSQuerySessionInformationW"));
        auto release = reinterpret_cast<Release>(GetProcAddress(handsFreeWts, "WTSFreeMemory"));
        LPWSTR buffer = nullptr;
        DWORD bytes = 0;
        bool known = query && release &&
            query(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION, WTSConnectState, &buffer, &bytes);
        if (known && buffer && bytes >= sizeof(WTS_CONNECTSTATE_CLASS)) {
            if (*reinterpret_cast<WTS_CONNECTSTATE_CLASS *>(buffer) != WTSActive) handsFreeAbsence.fetch_or(4u);
        } else known = false;
        if (buffer && release) release(buffer);
        HDESK desktop = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
        if (desktop) {
            wchar_t name[128]{};
            DWORD length = 0;
            known = known && GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name), &length);
            if (known && wcscmp(name, L"Default") != 0) handsFreeAbsence.fetch_or(1u);
            CloseDesktop(desktop);
        } else known = false;
        if (!known) {
            handsFreeUnregister(window);
            handsFreeGuardRegistered = false;
        }
    }
    if (!handsFreeGuardRegistered)
        std::fprintf(stderr, "Hands-free unavailable: session notification registration failed. Manual recording is unaffected.\n");
}

void stopHandsFreeGuard(HWND window) {
    if (handsFreeGuardRegistered && handsFreeUnregister) handsFreeUnregister(window);
    handsFreeGuardRegistered = false;
    handsFreeUnregister = nullptr;
    if (handsFreeWts) { FreeLibrary(handsFreeWts); handsFreeWts = nullptr; }
}
WindowState state;
CleanupPreview cleanupPreview;
SettingsSearch settingsSearch;
} // namespace jsti_window

int jsti_window_hands_free_guard_ready(void) {
    return handsFreeGuardRegistered && handsFreeAbsence == 0 ? 1 : 0;
}
namespace {
// Common Controls 6 gives the native edits, lists and drop-downs the current
// Windows look. The executable carries no manifest, so an activation context
// is created from one in a private temporary file for this thread.
ULONG_PTR activateVisualStyles() {
    static const char manifest[] =
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\"><dependency>"
        "<dependentAssembly><assemblyIdentity type=\"win32\" name=\"Microsoft.Windows.Common-Controls\" "
        "version=\"6.0.0.0\" processorArchitecture=\"*\" publicKeyToken=\"6595b64144ccf1df\" language=\"*\"/>"
        "</dependentAssembly></dependency></assembly>";
    wchar_t folder[MAX_PATH + 1] = {};
    const DWORD length = GetTempPathW(MAX_PATH, folder);
    if (length == 0 || length > MAX_PATH) return 0;
    wchar_t unique[40] = {};
    GUID identifier{};
    if (FAILED(CoCreateGuid(&identifier)) || !StringFromGUID2(identifier, unique, 40)) return 0;
    const std::wstring path = std::wstring(folder) + L"JustSpeakToIt-" + unique + L".manifest";
    std::string failure;
    HANDLE file = jsti::createPrivateFileHandle(jsti::utf8(path).c_str(), failure);
    if (file == INVALID_HANDLE_VALUE) return 0;
    DWORD written = 0;
    const bool saved = WriteFile(file, manifest, sizeof(manifest) - 1, &written, nullptr) &&
        written == sizeof(manifest) - 1;
    CloseHandle(file);
    ULONG_PTR cookie = 0;
    if (saved) {
        ACTCTXW context{};
        context.cbSize = sizeof(context);
        context.lpSource = path.c_str();
        HANDLE activation = CreateActCtxW(&context);
        if (activation != INVALID_HANDLE_VALUE) {
            if (!ActivateActCtx(activation, &cookie)) cookie = 0;
            ReleaseActCtx(activation);
        }
    }
    DeleteFileW(path.c_str());
    // Controls created from here on load Common Controls 6.
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES | ICC_WIN95_CLASSES};
    InitCommonControlsEx(&controls);
    return cookie;
}
} // namespace

int jsti_window_run(const char *const *models, size_t count, int selected,
                    JSTIWindowCallback callback, void *context, char *error, size_t capacity) {
    if (!models || count == 0 || !callback || count > 10000) return jsti::fail("No transcription models or event callback.", error, capacity);
    std::vector<std::wstring> names(count);
    for (size_t i = 0; i < count; ++i) {
        if (!jsti::wide(models[i], names[i])) return jsti::fail("A model label is not valid UTF-8.", error, capacity);
    }
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        if (state.running) return jsti::fail("The desktop window is already running.", error, capacity);
        if (!state.configuredModelModes.empty() && state.configuredModelModes.size() != count) {
            return jsti::fail("The model mode catalogue does not match the supplied model labels.", error, capacity);
        }
        state.modelNames = std::move(names);
        state.modelModes = state.configuredModelModes.empty() ? std::vector<int>(count, 0) : state.configuredModelModes;
        state.modelOrder.resize(count);
        for (size_t index = 0; index < count; ++index) state.modelOrder[index] = static_cast<int>(index);
        if (!state.pendingModels.empty()) {
            if (state.pendingModels.size() != count) return jsti::fail("The discovered model catalogue has the wrong slot count.", error, capacity);
            for (size_t index = 0; index < count; ++index) {
                const auto &row = state.pendingModels[index];
                if (row.mode != state.modelModes[index]) return jsti::fail("The discovered model catalogue has inconsistent modes.", error, capacity);
                state.modelNames[index] = row.name;
                state.modelOrder[index] = row.order;
            }
        }
        state.pendingModels.clear(); state.modelsChanged = false;
        state.localModelPreferencesChanged = false;
        std::fill(std::begin(state.pendingLocalModelPreferences), std::end(state.pendingLocalModelPreferences), -1);
        for (int mode = 0; mode < modeCount; ++mode) {
            const auto first = std::find(state.modelModes.begin(), state.modelModes.end(), mode);
            state.preferredModels[mode] = first == state.modelModes.end() ? -1 : static_cast<int>(first - state.modelModes.begin());
        }
        // Configured batch and live preferences belong to whichever source holds them.
        for (const int preferred : state.configuredPreferredModels) {
            if (preferred >= 0) state.preferredModels[state.modelModes[preferred]] = preferred;
        }
        if (selected < 0 || static_cast<size_t>(selected) >= count) {
            selected = state.configuredPreferredModels[0] >= 0 ? state.configuredPreferredModels[0] : -1;
            for (int mode = 0; selected < 0 && mode < modeCount; ++mode) selected = state.preferredModels[mode];
        }
        state.activeMode = state.modelModes[selected];
        state.preferredModels[state.activeMode] = selected;
        state.filteredModels.clear();
        if (state.microphones.empty()) state.microphones.push_back({"", L"Default communications microphone"});
        state.running = true;
        state.recording = 0;
        jsti::globalEscape::publish(0);
        state.cancelKeyHeld = false;
        state.microphonesChanged = false;
        state.pendingMicrophones.clear(); state.microphoneError.clear();
        state.posted = false;
        state.statusChanged = false;
        state.transcriptChanged = false;
        state.historyChanged = false;
        state.historySelectionProvided = false;
        state.historyInteractionRevision = 0;
        state.pendingHistoryRevision = 0;
        state.variantChanged = false;
        state.presentationChanged = false;
        state.pendingPresentation = {};
        state.pendingVariantRecord.clear();
        state.pendingVariant = -1;
        state.pendingVariantSwitchable = false;
        state.playbackChanged = false;
        state.pendingPlaybackRecord.clear();
        state.pendingPlaybackState = playbackIdle;
        state.pendingPlaybackText.clear();
        state.pendingHistory.clear(); state.pendingHistorySelection.clear(); state.selectedHistoryID.clear();
        state.allHistoryIDs.clear();
        state.status.clear(); state.transcript.clear();
    }
    state.callback = callback; state.context = context;
    state.controls.clear();
    state.displayedHistory.clear();
    state.displayedVariant = -1;
    state.variantSwitchable = false;
    state.historyPresentationReady = false;
    state.requestedVariant = -1;
    state.displayedPlayback = playbackIdle;
    state.suppressSearchEvents = false;
    // The process may already have a manifest-defined awareness context.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const ULONG_PTR visualStyles = activateVisualStyles();
    jsti::chrome::startup();
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSW type{};
    type.lpfnWndProc = procedure;
    type.hInstance = instance;
    type.lpszClassName = L"JustSpeakToItWindows";
    type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    type.hbrBackground = nullptr;
    const ATOM registered = RegisterClassW(&type);
    HWND window = registered ? CreateWindowExW(WS_EX_CONTROLPARENT, type.lpszClassName,
        L"Just Speak to It", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, CW_USEDEFAULT, CW_USEDEFAULT,
        1180, 820, nullptr, nullptr, instance, nullptr) : nullptr;
    int outcome = 0;
    std::string iconFailure;
    if (window && !jsti::appIcon::refresh(window, GetDpiForWindow(window), iconFailure)) {
        outcome = jsti::fail(iconFailure, error, capacity);
        DestroyWindow(window);
        window = nullptr;
    }
    if (!window) {
        if (!outcome) outcome = jsti::fail(jsti::systemError("Creating native desktop window"), error, capacity);
    } else {
        std::unique_ptr<SidebarBindings> initialSidebar;
        std::unique_ptr<JSTIVisualDensity> initialDensity;
        std::unique_ptr<ShellPresentation> initialShell;
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.window = window;
            initialSidebar = state.sidebarDelivery.claimInitial();
            initialDensity = state.densityDelivery.claimInitial();
            initialShell = state.shellDelivery.claimInitial();
        }
        // Optional report UI may be unavailable without preventing dictation.
        jsti_issue_report_attach(window, callback, context);
        if (initialSidebar) state.sidebar = std::move(*initialSidebar);
        initialSidebar.reset();
        if (initialDensity) { visualDensity = *initialDensity; layout(window); }
        initialDensity.reset();
        shell = initialShell ? *initialShell : ShellPresentation{};
        initialShell.reset();
        applySidebarBindings(window);
        // Optional: without a notification area the app keeps its taskbar button.
        applyShell(window);
        const bool login = jsti::login::launchedAtLogin();
        // A login launch leaves the focus where it is: minimised, or only in
        // the notification area when the app has no taskbar button.
        if (!(login && trayResident)) {
            ShowWindow(window, login ? SW_SHOWMINNOACTIVE : SW_SHOWDEFAULT);
            UpdateWindow(window);
        }
        emit(window, JSTI_EVENT_READY);
        std::string shortcutFailure;
        if (IsWindow(window) && !jsti_hotkey_start(window, shortcutFailure)) showFailure(window, shortcutFailure);
        std::string actionShortcutFailure;
        if (IsWindow(window) && !jsti_action_shortcuts_start(window, actionShortcutFailure))
            showFailure(window, actionShortcutFailure);
        if (IsWindow(window)) applySidebarBindings(window);
        MSG message{};
        BOOL result;
        while ((result = GetMessageW(&message, nullptr, 0, 0)) > 0) {
            if (cancelKeyMessage(window, message)) continue;
            if (sidebarKeyMessage(window, message)) continue;
            if (jsti_action_shortcut_key_message(window, message)) continue;
            if (settingsSearchKeyMessage(window, message) || settingsSearchMouseMessage(window, message)) continue;
            if (!jsti_issue_report_message(&message) && !jsti_history_filters_message(&message) && !jsti_guide_message(&message) &&
                !jsti_permissions_message(&message) && !IsDialogMessageW(window, &message)) {
                TranslateMessage(&message); DispatchMessageW(&message);
            }
        }
        if (result < 0) {
            outcome = jsti::fail(jsti::systemError("Reading desktop messages"), error, capacity);
            DestroyWindow(window);
        }
    }
    {
        std::string failure;
        if (!jsti::globalEscape::stop(failure) && !outcome) {
            outcome = jsti::fail(
                failure.empty() ? "The active-only Escape listener could not be removed." : failure, error, capacity);
        }
    }
    jsti_issue_report_shutdown();
    jsti::hud::destroy();
    releaseShell();
    state.font = nullptr;
    state.controls.clear(); state.callback = nullptr; state.context = nullptr;
    jsti::appIcon::destroy();
    if (visualStyles) DeactivateActCtx(0, visualStyles);
    state.displayedHistory.clear();
    if (registered) UnregisterClassW(type.lpszClassName, instance);
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.running = false; state.window = nullptr;
        state.sidebarDelivery.retire();
        state.densityDelivery.retire();
        state.shellDelivery.retire();
    }
    return outcome;
}
