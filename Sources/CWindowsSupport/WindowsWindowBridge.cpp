// The jsti_window_* C ABI that stages host updates for the UI thread.
#include "WindowsWindowInternal.hpp"

// Shortcut events from WindowsHotKey.cpp, on the UI thread. A press-to-toggle
// press behaves exactly like the former fixed shortcut; gesture presses carry
// the selected microphone so the host can start with the device in view.
void jsti_window_hotkey_event(HWND window, int event) {
    switch (event) {
    case JSTI_EVENT_TOGGLE_RECORDING:
        if (IsWindowEnabled(GetDlgItem(window, recordID))) emitRecording(window);
        break;
    case JSTI_EVENT_HOTKEY_DOWN: {
        const std::string device = selectedMicrophone(window);
        emit(window, event, device.c_str());
        break;
    }
    case JSTI_EVENT_HOTKEY_UP:
    case JSTI_EVENT_HOTKEY_DEADLINE: emit(window, event); break;
    default: break;
    }
}

int jsti_window_configure_about(const char *details, const JSTIAboutLink *links, size_t count) {
    if (!details || !links || count == 0 || count > 8 || std::strlen(details) > 4096) return -1;
    std::wstring information;
    if (!jsti::wide(details, information) || information.empty()) return -1;
    std::vector<AboutLink> copied;
    for (size_t i = 0; i < count; ++i) {
        AboutLink link;
        if (!links[i].title || !links[i].url || std::strlen(links[i].title) > 128 ||
            std::strlen(links[i].url) > 2048 || !jsti::wide(links[i].title, link.title) ||
            !jsti::wide(links[i].url, link.url) || link.title.empty() ||
            link.title.find_first_of(L"\r\n\t") != std::wstring::npos ||
            link.url.compare(0, 8, L"https://") != 0 || link.url.size() <= 8 ||
            link.url.find_first_of(L" \r\n\t") != std::wstring::npos) return -1;
        copied.push_back(std::move(link));
    }
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.running) return -1;
    state.aboutDetails = std::move(information);
    state.aboutLinks = std::move(copied);
    return 0;
}

// Action shortcuts from WindowsActionShortcuts.cpp, on the UI thread. Each runs
// its corresponding Host action or enabled button/sidebar behavior.
void jsti_window_action_command(HWND window, int run, const char *page) {
    if (!IsWindow(window) || !IsWindowEnabled(window)) return;
    switch (run) {
    case JSTI_ACTION_RUN_RECORD: jsti_window_hotkey_event(window, JSTI_EVENT_TOGGLE_RECORDING); break;
    case JSTI_ACTION_RUN_PAGE:
        for (int index = 0; page && index < pageCount; ++index) {
            HWND row = GetDlgItem(window, navBaseID + index);
            if (std::strcmp(pageInfo[index].name, page) != 0) continue;
            if (IsWindowEnabled(row) && IsWindowVisible(row)) showPage(window, index);
            break;
        }
        break;
    case JSTI_ACTION_RUN_PLAY_PAUSE:
        emit(window, JSTI_EVENT_SPEECH_PAUSE);
        break;
    case JSTI_ACTION_RUN_STOP_SPEECH:
        emit(window, JSTI_EVENT_HISTORY_STOP);
        break;
    case JSTI_ACTION_RUN_API_KEYS: case JSTI_ACTION_RUN_PERMISSIONS: case JSTI_ACTION_RUN_COMPARE: {
        const int button = run == JSTI_ACTION_RUN_API_KEYS ? apiKeysID
            : run == JSTI_ACTION_RUN_PERMISSIONS ? permissionsID : comparisonID;
        HWND control = GetDlgItem(window, button);
        if (control && IsWindowEnabled(control))
            SendMessageW(window, WM_COMMAND, MAKEWPARAM(button, BN_CLICKED), reinterpret_cast<LPARAM>(control));
        break;
    }
    case JSTI_ACTION_RUN_QUICK_VOICE_1: case JSTI_ACTION_RUN_QUICK_VOICE_2: case JSTI_ACTION_RUN_QUICK_VOICE_3: {
        // Voice Output settings are locked while recording, as its buttons are.
        if (!IsWindowEnabled(GetDlgItem(window, voiceSettingsID))) break;
        const char *slot = run == JSTI_ACTION_RUN_QUICK_VOICE_1 ? "1" : run == JSTI_ACTION_RUN_QUICK_VOICE_2 ? "2" : "3";
        emit(window, JSTI_EVENT_QUICK_VOICE, slot);
        break;
    }
    // The Host decides whether output can run now; the latest item may be hidden by filters.
    case JSTI_ACTION_RUN_PASTE_LAST_HISTORY: emit(window, JSTI_EVENT_PASTE_LAST_HISTORY); break;
    case JSTI_ACTION_RUN_SPEAK_SELECTED_TEXT: emit(window, JSTI_EVENT_SPEAK_SELECTED_TEXT); break;
    case JSTI_ACTION_RUN_SPEAK_CLIPBOARD: emit(window, JSTI_EVENT_SPEAK_CLIPBOARD); break;
    case JSTI_ACTION_RUN_TROUBLESHOOTING: jsti_show_troubleshooting(window); break;
    case JSTI_ACTION_RUN_VOICE_EDIT: emit(window, JSTI_EVENT_VOICE_EDIT); break;
    default: break;
    }
}

int jsti_window_set_automation(int enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    state.automationEnabled = enabled == 1;
    if (state.window && !state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
    return 0;
}

int jsti_window_set_login_item(int value, const char *detail) {
    std::wstring note;
    if (value < jsti::login::off || value > jsti::login::unavailable || !jsti::wide(detail, note)) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    state.loginItem = value;
    state.loginItemPending = false;
    state.loginItemDetail.swap(note);
    if (state.window && !state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
    return 0;
}

int jsti_window_recording_state() {
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.recording;
}

int jsti_window_configure_global_escape(int enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.running) return -1;
    state.globalEscapeEnabled = enabled == 1;
    return 0;
}

int jsti_window_global_escape_is_current(uint64_t token) {
    return jsti::globalEscape::current(token) ? 1 : 0;
}

int jsti_window_set_voice_edit_escape(int active) {
    if (active != 0 && active != 1) return -1;
    jsti::globalEscape::editing(active == 1);
    return 0;
}

int jsti_window_set_escape_cancellation(int enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    jsti::globalEscape::configure(enabled == 1);
    if (state.window && !state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) return -1;
    }
    return 0;
}

int jsti_window_update(const char *status, const char *transcript, int recording) {
    std::wstring wideStatus, wideTranscript;
    if ((status && !jsti::wide(status, wideStatus)) || (transcript && !jsti::wide(transcript, wideTranscript)) ||
        recording < -1 || recording > 2) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window) return -1;
    if (status) { state.status = std::move(wideStatus); state.statusChanged = true; }
    if (transcript) { state.transcript = std::move(wideTranscript); state.transcriptChanged = true; }
    if (recording >= 0) {
        state.recording = recording;
        jsti::globalEscape::publish(recording);
    }
    if (!state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) return -1;
    }
    return 0;
}

void jsti_window_request_close(void) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, WM_CLOSE, 0, 0);
}

void jsti_window_request_profiles(void) {
    bool posted = false;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        posted = state.window && PostMessageW(state.window, profilesMessage, 0, 0);
    }
    if (!posted) jsti_cancel_profiles_request();
}

void jsti_window_request_guide(void) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, guideMessage, 0, 0);
}

void jsti_window_request_permissions(void) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, permissionsMessage, 0, 0);
}

void jsti_window_request_api_keys(void) {
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, apiKeysMessage, 0, 0);
}

int jsti_window_set_insights(const JSTIInsights *all, const JSTIInsights *visible) {
    if (!all || !visible) return -1;
    try {
        std::wstring values[2][5];
        const JSTIInsights *groups[2] = {all, visible};
        for (int group = 0; group < 2; ++group) {
            const char *fields[5] = {groups[group]->sessions, groups[group]->errors, groups[group]->recording_time,
                                     groups[group]->average_length, groups[group]->spend};
            for (int index = 0; index < 5; ++index) {
                if (!fields[index] || !jsti::wide(fields[index], values[group][index]) ||
                    values[group][index].size() > 64) return -1;
            }
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        if (!state.window) return -1;
        for (int group = 0; group < 2; ++group) {
            for (int index = 0; index < 5; ++index) state.insights[group][index] = std::move(values[group][index]);
        }
        state.insightsChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_hud(int phase, const char *headline, const char *subheadline, const char *live_text,
                        int display_milliseconds, int compact) {
    return jsti_window_set_hud_layout(phase, headline, subheadline, live_text, display_milliseconds, compact, 0);
}

int jsti_window_set_hud_layout(int phase, const char *headline, const char *subheadline, const char *live_text,
                               int display_milliseconds, int compact, int expanded) {
    try {
        if ((compact != 0 && compact != 1) || (expanded != 0 && expanded != 1)) return -1;
        std::wstring title, detail, live;
        if (!jsti::wide(headline ? headline : "", title) || !jsti::wide(subheadline ? subheadline : "", detail) ||
            !jsti::wide(live_text ? live_text : "", live) ||
            !jsti::hud::stage(phase, std::move(title), std::move(detail), std::move(live),
                              display_milliseconds, compact != 0, expanded != 0)) {
            return -1;
        }
        std::lock_guard<std::mutex> lock(state.mutex);
        return state.window && PostMessageW(state.window, hudMessage, 0, 0) ? 0 : -1;
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_appearance(int appearance) {
    if (appearance < 0 || appearance > 2) return -1;
    jsti::chrome::setAppearance(appearance);
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.window) PostMessageW(state.window, appearanceMessage, 0, 0);
    return 0;
}

int jsti_window_show_page(int page) {
    if (page < 0 || page >= pageCount) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    return state.window && PostMessageW(state.window, pageMessage, static_cast<WPARAM>(page), 0) ? 0 : -1;
}
