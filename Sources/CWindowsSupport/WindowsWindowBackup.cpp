// General > Backup and audio cleanup: migration backups, restore and cleanup confirmations.
#include "WindowsWindowBackup.hpp"

namespace jsti_window {
namespace {
// The audio cleanup confirmation and backup report waiting for the UI thread,
// under WindowState::mutex.
struct Housekeeping {
    std::string audioCleanupToken;
    size_t audioCleanupCount = 0;
    std::wstring migrationReport;
};
Housekeeping housekeeping;
} // namespace

void takeAudioCleanup(std::string &token, size_t &count) {
    token.swap(housekeeping.audioCleanupToken);
    count = housekeeping.audioCleanupCount;
}

std::wstring takeMigrationReport() {
    std::wstring report;
    report.swap(housekeeping.migrationReport);
    return report;
}

void retireHousekeeping() {
    housekeeping.audioCleanupToken.clear();
    housekeeping.migrationReport.clear();
}


void emitMigrationInspection(const std::string &path) {
    if (state.callback) state.callback(JSTI_EVENT_MIGRATION_INSPECT, path.c_str(), 0, state.context);
}

void inspectMigrationBackup(HWND window) {
    std::vector<wchar_t> path(32768);
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFile = path.data();
    chooser.nMaxFile = static_cast<DWORD>(path.size());
    chooser.lpstrFilter = L"ZIP backups (*.zip)\0*.zip\0\0";
    chooser.lpstrTitle = L"Inspect backup (no data will be imported)";
    chooser.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (!GetOpenFileNameW(&chooser)) {
        const DWORD code = CommDlgExtendedError();
        if (code) showFailure(window, jsti::systemError("Choosing backup for inspection", code));
        return;
    }
    const std::string selected = jsti::utf8(path.data());
    if (selected.empty()) {
        showFailure(window, "Windows returned an invalid backup path. Choose a local ZIP file.");
        return;
    }
    emitMigrationInspection(selected);
}

int migrationBackupOptions(HWND window) {
    const int audio = SendDlgItemMessageW(window, backupAudioID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 1 : 0;
    const int profiles = SendDlgItemMessageW(window, backupProfilesID, BM_GETCHECK, 0, 0) == BST_CHECKED ? 2 : 0;
    return audio | profiles;
}

void emitMigrationBackup(HWND window, const std::string &path, int options) {
    if (state.callback) state.callback(JSTI_EVENT_MIGRATION_EXPORT, path.c_str(), options, state.context);
}

void exportMigrationBackup(HWND window) {
    const int options = migrationBackupOptions(window);
    std::vector<wchar_t> path(32768);
    const std::wstring name = L"JustSpeakToIt-History.zip";
    std::copy(name.begin(), name.end(), path.begin());
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFilter = L"ZIP backups (*.zip)\0*.zip\0\0";
    chooser.lpstrFile = path.data();
    chooser.nMaxFile = static_cast<DWORD>(path.size());
    chooser.lpstrDefExt = L"zip";
    chooser.lpstrTitle = L"Save ZIP backup (existing files are never replaced)";
    chooser.Flags = OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER | OFN_DONTADDTORECENT;
    if (!GetSaveFileNameW(&chooser)) {
        const DWORD code = CommDlgExtendedError();
        if (code) showFailure(window, jsti::systemError("Choosing History backup destination", code));
        return;
    }
    const DWORD attributes = GetFileAttributesW(path.data());
    if (attributes != INVALID_FILE_ATTRIBUTES) {
        showFailure(window, "A file or folder already exists at that destination. "
                    "Choose a new backup filename; existing files are never replaced.");
        return;
    }
    const DWORD code = GetLastError();
    if (code != ERROR_FILE_NOT_FOUND) {
        showFailure(window, jsti::systemError("Checking History backup destination", code));
        return;
    }
    const std::string selected = jsti::utf8(path.data());
    if (selected.empty()) {
        showFailure(window, "Windows returned an invalid History backup path. Choose another filename.");
        return;
    }
    emitMigrationBackup(window, selected, options);
}
} // namespace jsti_window

int jsti_window_confirm_audio_cleanup(const char *token, size_t count, char *error, size_t capacity) {
    std::wstring checked;
    if (!token || !jsti::wide(token, checked) || checked.empty() || count == 0) {
        return jsti::fail("The recording audio confirmation is invalid.", error, capacity);
    }
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window || !housekeeping.audioCleanupToken.empty()) {
        return jsti::fail("The recording audio confirmation is unavailable.", error, capacity);
    }
    housekeeping.audioCleanupToken = token;
    housekeeping.audioCleanupCount = count;
    if (!PostMessageW(state.window, audioCleanupMessage, 0, 0)) {
        housekeeping.audioCleanupToken.clear();
        return jsti::fail("Could not show the recording audio confirmation.", error, capacity);
    }
    return 0;
}

int jsti_window_confirm_migration_restore(const char *token, const char *text, int offers_replace,
                                          char *error, size_t capacity) {
    std::wstring checkedToken, preview;
    if (!token || !jsti::wide(token, checkedToken) || checkedToken.empty() || !text || !jsti::wide(text, preview) ||
        preview.empty() || (offers_replace != 0 && offers_replace != 1)) {
        return jsti::fail("The backup restore preview is invalid.", error, capacity);
    }
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window || !jsti::migrationRestore::stage(token, std::move(preview), offers_replace == 1)) {
        return jsti::fail("The backup restore preview is unavailable.", error, capacity);
    }
    if (!PostMessageW(state.window, jsti::migrationRestore::message, 0, 0)) {
        jsti::migrationRestore::clear();
        return jsti::fail("Could not show the backup restore preview.", error, capacity);
    }
    return 0;
}

int jsti_window_show_migration_report(const char *text, char *error, size_t capacity) {
    std::wstring report;
    if (!text || !jsti::wide(text, report) || report.empty()) {
        return jsti::fail("The backup inspection report is invalid.", error, capacity);
    }
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window || !housekeeping.migrationReport.empty()) {
        return jsti::fail("The backup inspection report is unavailable.", error, capacity);
    }
    housekeeping.migrationReport = std::move(report);
    if (!state.posted) {
        state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
        if (!state.posted) {
            housekeeping.migrationReport.clear();
            return jsti::fail("Could not show the backup inspection report.", error, capacity);
        }
    }
    return 0;
}
