// Dashboard: the status line, the latest transcript and the History totals.
#include "WindowsWindowDashboardPage.hpp"

namespace jsti_window {
namespace {
// Staged under WindowState::mutex.
struct DashboardPageState {
    bool statusChanged = false;
    bool transcriptChanged = false;
    std::wstring status;
    std::wstring transcript;
    std::wstring insights[2][5];
    bool insightsChanged = false;
};
DashboardPageState dashboard;
} // namespace

void stageDashboardStatus(std::wstring status) {
    dashboard.status = std::move(status);
    dashboard.statusChanged = true;
}

void stageDashboardTranscript(std::wstring transcript) {
    dashboard.transcript = std::move(transcript);
    dashboard.transcriptChanged = true;
}

DashboardUpdate takeDashboardUpdate() {
    DashboardUpdate update;
    update.status.swap(dashboard.status);
    update.transcript.swap(dashboard.transcript);
    update.statusChanged = dashboard.statusChanged;
    update.transcriptChanged = dashboard.transcriptChanged;
    dashboard.statusChanged = dashboard.transcriptChanged = false;
    return update;
}

void resetDashboard() {
    dashboard.statusChanged = dashboard.transcriptChanged = false;
    dashboard.status.clear();
    dashboard.transcript.clear();
}

bool takeDashboardInsights(std::wstring (&values)[2][5]) {
    if (!dashboard.insightsChanged) return false;
    dashboard.insightsChanged = false;
    for (int group = 0; group < 2; ++group)
        for (int index = 0; index < 5; ++index) values[group][index] = dashboard.insights[group][index];
    return true;
}

} // namespace jsti_window

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
            for (int index = 0; index < 5; ++index) dashboard.insights[group][index] = std::move(values[group][index]);
        }
        dashboard.insightsChanged = true;
        if (!state.posted) {
            state.posted = PostMessageW(state.window, updateMessage, 0, 0) != 0;
            if (!state.posted) return -1;
        }
        return 0;
    } catch (const std::exception &) { return -1; }
}
