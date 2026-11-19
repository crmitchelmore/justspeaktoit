// Dashboard: the status line, the latest transcript and the History totals,
// owned by WindowsWindowDashboard.cpp. The host stages them under
// WindowState::mutex and the UI thread takes them in applyUpdate.
#pragma once

#include "WindowsWindowInternal.hpp"

namespace jsti_window {

struct DashboardUpdate {
    bool statusChanged = false, transcriptChanged = false;
    std::wstring status, transcript;
};

// Each of these requires the caller to hold WindowState::mutex.
void stageDashboardStatus(std::wstring status);
void stageDashboardTranscript(std::wstring transcript);
// Moves the staged status and transcript out and clears their change flags.
DashboardUpdate takeDashboardUpdate();
void resetDashboard();
// Copies the totals ([all, visible][sessions, errors, recording time, average,
// spend]) when they changed since the last call.
bool takeDashboardInsights(std::wstring (&values)[2][5]);

} // namespace jsti_window
