#include "WindowsMigrationRestore.hpp"
#include <commdlg.h>
#include <mutex>
#include <vector>

namespace {
struct Pending {
    std::string token;
    std::wstring text;
    bool offersReplace = false;
};
std::mutex mutex;
Pending pending;

int chooseAction(HWND window, const Pending &staged) {
    const std::wstring title = L"Restore backup: review before anything is written";
    if (!staged.offersReplace) {
        const std::wstring body = staged.text +
            L"\n\nChoose OK to merge this backup, or Cancel to leave everything as it is.";
        return MessageBoxW(window, body.c_str(), title.c_str(), MB_OKCANCEL | MB_ICONINFORMATION | MB_DEFBUTTON2)
            == IDOK ? 1 : 0;
    }
    const std::wstring body = staged.text +
        L"\n\nYes merges the backup. No replaces app profiles with the backup's profiles "
        L"(everything else is still merged). Cancel leaves everything as it is.";
    const int answer = MessageBoxW(window, body.c_str(), title.c_str(),
        MB_YESNOCANCEL | MB_ICONINFORMATION | MB_DEFBUTTON3);
    if (answer == IDYES) return 1;
    if (answer != IDNO) return 0;
    const int confirmed = MessageBoxW(window,
        L"Replace your app profiles with the profiles in this backup?\n\n"
        L"Profiles that are not in the backup will be removed. History is still only merged. "
        L"If anything fails, every change is put back.",
        L"Replace app profiles?", MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
    return confirmed == IDYES ? 2 : 0;
}
}

namespace jsti::migrationRestore {
bool stage(const std::string &token, std::wstring text, bool offersReplace) {
    std::lock_guard<std::mutex> lock(mutex);
    if (token.empty() || text.empty() || !pending.token.empty()) return false;
    pending.token = token;
    pending.text = std::move(text);
    pending.offersReplace = offersReplace;
    return true;
}

void clear() {
    std::lock_guard<std::mutex> lock(mutex);
    pending = Pending{};
}

void present(HWND window, bool available, JSTIWindowCallback callback, void *context) {
    Pending staged;
    {
        std::lock_guard<std::mutex> lock(mutex);
        std::swap(staged, pending);
    }
    if (staged.token.empty()) return;
    const int choice = available && IsWindow(window) ? chooseAction(window, staged) : 0;
    if (callback) callback(JSTI_EVENT_MIGRATION_RESTORE_RESPONSE, staged.token.c_str(), choice, context);
}

std::string choose(HWND window, std::string &failure) {
    failure.clear();
    std::vector<wchar_t> path(32768);
    OPENFILENAMEW chooser{};
    chooser.lStructSize = sizeof(chooser);
    chooser.hwndOwner = window;
    chooser.lpstrFile = path.data();
    chooser.nMaxFile = static_cast<DWORD>(path.size());
    chooser.lpstrFilter = L"ZIP backups (*.zip)\0*.zip\0\0";
    chooser.lpstrTitle = L"Restore backup (you will see a preview first)";
    chooser.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
    if (!GetOpenFileNameW(&chooser)) {
        const DWORD code = CommDlgExtendedError();
        if (code) failure = jsti::systemError("Choosing backup to restore", code);
        return {};
    }
    const std::string selected = jsti::utf8(path.data());
    if (selected.empty()) failure = "Windows returned an invalid backup path. Choose a local ZIP file.";
    return selected;
}
}
