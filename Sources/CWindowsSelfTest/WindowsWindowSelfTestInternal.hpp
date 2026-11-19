// Shared by the main window self-test files (jsti_window_self_test).
#pragma once

#include "CWindowsSelfTest.h"
#include "../CWindowsSupport/WindowsWindowInternal.hpp"
#include <functional>
#include <string>

namespace jsti_window {

// The last window event the checks observed instead of reporting it.
struct WindowCheckEvent { int event = 0; std::string id; int model = -1; int calls = 0; };

// What every stage of the main window check works on.
struct WindowCheck {
    HWND window;
    WindowCheckEvent &observed;
    std::string &failure;
    // Shrinks the window to its minimum size and checks no control falls outside it.
    std::function<bool()> checkBounds;
    // Chooses model mode `mode` and checks it selected the global model `expected`.
    bool changeMode(int mode, int expected);
};

// Stages, in order (WindowsWindowModelsSelfTest.cpp, WindowsWindowHistorySelfTest.cpp).
bool windowModelAndMicrophoneChecks(WindowCheck &check);
bool windowHistoryChecks(WindowCheck &check);
bool windowRecordingLockChecks(WindowCheck &check);
bool windowModelSourceChecks(WindowCheck &check);

// Independent scenarios (WindowsWindowScenarioSelfTest.cpp).
bool sidebarStartupSelfTest();
bool shellSelfTest(std::string &failure);
bool cleanupPreviewSelfTest(HWND window);
bool settingsSearchSelfTest(HWND window);
bool screenReaderSelfTest(HWND window, std::string &failure);
bool densityAndSidebarSelfTest(HWND window, std::string &failure);
void jsti_smoke_stage(const char *stage);

} // namespace jsti_window
