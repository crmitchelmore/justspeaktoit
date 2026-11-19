// General page: the automation switch and Launch at login.
#include "WindowsWindowGeneralPage.hpp"

namespace jsti_window {
namespace {
// Host reports, under WindowState::mutex.
GeneralSettings general;
// UI thread only.
std::wstring loginNote;
} // namespace

GeneralSettings generalSettings() {
    std::lock_guard<std::mutex> lock(state.mutex);
    return general;
}

// The CLI and MCP setup dialog shows and changes the same automation state as
// General's switch: the host's last report, and the same toggle event.
bool automationShownEnabled() {
    std::lock_guard<std::mutex> lock(state.mutex);
    return general.automationEnabled;
}

bool claimLoginItemToggle(bool &requested) {
    std::lock_guard<std::mutex> lock(state.mutex);
    const int login = general.loginItem;
    if (general.loginItemPending || (login != jsti::login::off && login != jsti::login::on)) return false;
    general.loginItemPending = true;
    requested = login == jsti::login::off;
    return true;
}

void restoreLoginItem(int value, const std::wstring &detail) {
    general.loginItem = value;
    general.loginItemDetail = detail;
    general.loginItemPending = false;
}

const std::wstring &loginItemNote() { return loginNote; }

bool replaceLoginItemNote(std::wstring note) {
    if (note == loginNote) return false;
    loginNote.swap(note);
    return true;
}

} // namespace jsti_window

int jsti_window_set_automation(int enabled) {
    if (enabled != 0 && enabled != 1) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    general.automationEnabled = enabled == 1;
    if (state.window && !state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
    return 0;
}

int jsti_window_set_login_item(int value, const char *detail) {
    std::wstring note;
    if (value < jsti::login::off || value > jsti::login::unavailable || !jsti::wide(detail, note)) return -1;
    std::lock_guard<std::mutex> lock(state.mutex);
    general.loginItem = value;
    general.loginItemPending = false;
    general.loginItemDetail.swap(note);
    if (state.window && !state.posted) state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
    return 0;
}
