// The screenshot tour: a fixed sequence of pages and states captured for the docs.
#include "WindowsWindowInternal.hpp"

namespace jsti_window {
namespace {
// The screenshot tour's progress (UI thread). Only this file reads or writes it.
struct TourState {
    std::wstring directory;
    int step = -1;
};
TourState tour;
} // namespace

// The screenshot tour: every page, then the dashboard and History in dark
// mode, then recording/HUD states, the light/dark filter editors, the
// expanded/compact HUD variants, and the General page in dark mode. Each
// step is saved as NN-name.bmp; the window closes afterwards.
enum TourStep { tourDarkDashboard = pageCount, tourDarkHistory, tourDashboardRecording, tourHUDRecording,
                tourHUDCompleted, tourHistoryFilters, tourDarkHistoryFilters, tourExpandedRecording,
                tourCompactRecording, tourCompactCompleted, tourGeneralDark, tourSteps };

std::string tourName(int step) {
    if (step < pageCount) return pageInfo[step].name;
    const char *const extra[] = {"dashboard-dark", "history-dark", "dashboard-recording", "hud-recording",
                                 "hud-completed", "history-filters", "history-filters-dark",
                                 "hud-expanded-recording", "hud-compact-recording", "hud-compact-completed",
                                 "general-dark"};
    return extra[step - pageCount];
}

void tourShow(HWND window, int step) {
    if (step < pageCount) {
        showPage(window, step);
    } else if (step == tourDarkDashboard) {
        jsti::chrome::setAppearance(2);
        SendDlgItemMessageW(window, appearanceID, CB_SETCURSEL, 2, 0);
        applyTheme(window);
        showPage(window, dashboardPage);
    } else if (step == tourDarkHistory) {
        showPage(window, historyPage);
    } else if (step == tourGeneralDark) {
        state.displayedRecording = 0;
        jsti::chrome::setAppearance(2);
        applyTheme(window);
        updateHistoryControls(window, 0);
        updateSettingsButtons(window, 0);
        showPage(window, generalPage);
    } else if (step == tourHistoryFilters || step == tourDarkHistoryFilters) {
        const JSTIHistoryFilterModel models[] = {
            {"model/sample", "Sample transcription model", 0},
            {"model/long", "An imported transcription model with a long descriptive name and vocabulary context", 0}
        };
        if (jsti_window_set_history_filters(models, 2, 0, "", "") != 0) {
            emit(window, JSTI_EVENT_ERROR, "Could not prepare the sample History filter editor.");
            PostMessageW(window, WM_CLOSE, 0, 0);
            return;
        }
        state.displayedRecording = 0;
        jsti::chrome::setAppearance(step == tourHistoryFilters ? 1 : 2);
        applyTheme(window);
        showPage(window, historyPage);
        jsti_show_history_filters(window, [](const std::string &) {});
    } else if (step == tourHUDRecording) {
        jsti::hud::stage(1, L"Recording", L"Capturing audio",
                         L"Could we move the catch-up to Friday? That gives us a little more time");
        jsti::hud::apply();
    } else if (step == tourHUDCompleted) {
        jsti::hud::stage(5, L"Completed", L"Saved. Inserted into the original text field.", L"");
        jsti::hud::apply();
    } else if (step == tourExpandedRecording) {
        jsti::hud::stage(1, L"Recording", L"Capturing audio",
                         L"Could we move the catch-up to Friday? That gives us a little more time to finish "
                         L"the proposal and review the notes together before sending them to the team.", 0, false, true);
        jsti::hud::apply();
    } else if (step == tourCompactRecording) {
        jsti::hud::stage(1, L"Recording", L"Capturing audio",
                         L"Could we move the catch-up to Friday? That gives us a little more time", 0, true);
        jsti::hud::apply();
    } else if (step == tourCompactCompleted) {
        jsti::hud::stage(5, L"Completed", L"Saved. Inserted into the original text field.", L"", 2400, true);
        jsti::hud::apply();
    } else {
        // Late, because it replaces the displayed transcript.
        state.displayedRecording = 1;
        SetDlgItemTextW(window, transcriptID, L"Could we move the catch-up to Friday? That gives us a little");
        SetDlgItemTextW(window, statusID, L"Recording… Press Ctrl+Alt+Space again to stop.");
        showPage(window, dashboardPage);
    }
    UpdateWindow(window);
    SetTimer(window, tourTimerID, 700, nullptr);
}

bool tourBegin(HWND window, const std::wstring &directory) {
    if (tour.step >= 0) return false;
    tour.directory = directory;
    tour.step = 0;
    tourShow(window, 0);
    return true;
}

void tourStep(HWND window) {
    if (tour.step < 0 || tour.step >= tourSteps) return;
    char name[64];
    snprintf(name, sizeof name, "%02d-%s.bmp", tour.step + 1, tourName(tour.step).c_str());
    const std::string path = jsti::utf8(tour.directory) + "\\" + name;
    char error[512] = {};
    std::string hudError;
    std::wstring widePath;
    if (tour.step == tourHistoryFilters || tour.step == tourDarkHistoryFilters) {
        HWND filters = jsti_history_filters_window();
        if (jsti_owned_window_save_snapshot(filters, path.c_str(), error, sizeof error) != 0) {
            emit(window, JSTI_EVENT_ERROR, error);
        }
        if (filters) DestroyWindow(filters);
    } else if (tour.step >= tourHUDRecording && tour.step <= tourCompactCompleted) {
        // The HUD is its own layered window; it is drawn straight to the file.
        if (!jsti::wide(path.c_str(), widePath) || !jsti::hud::saveSnapshot(widePath, hudError)) {
            emit(window, JSTI_EVENT_ERROR, hudError.empty() ? "The HUD snapshot path is invalid." : hudError.c_str());
        }
    } else if (jsti_window_save_snapshot(path.c_str(), error, sizeof error) != 0) {
        emit(window, JSTI_EVENT_ERROR, error);
    }
    ++tour.step;
    if (tour.step < tourSteps) tourShow(window, tour.step);
    else {
        std::string comparisonError;
        if (!jsti_comparison_self_test(window, comparisonError, jsti::utf8(tour.directory)))
            emit(window, JSTI_EVENT_ERROR, comparisonError.c_str());
        PostMessageW(window, WM_CLOSE, 0, 0);
    }
}
} // namespace jsti_window

int jsti_window_screenshot_tour(const char *directory, char *error, size_t capacity) {
    std::wstring folder;
    if (!directory || !jsti::wide(directory, folder) || folder.empty()) {
        return jsti::fail("No screenshot folder supplied.", error, capacity);
    }
    if (!CreateDirectoryW(folder.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        return jsti::fail(jsti::systemError("Creating the screenshot folder"), error, capacity);
    }
    auto owned = std::make_unique<std::wstring>(std::move(folder));
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!state.window || !PostMessageW(state.window, tourMessage, 0, reinterpret_cast<LPARAM>(owned.get()))) {
        return jsti::fail("The window is not running.", error, capacity);
    }
    owned.release();
    return 0;
}
