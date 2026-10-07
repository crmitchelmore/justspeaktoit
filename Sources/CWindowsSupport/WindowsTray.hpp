#pragma once

#include "WindowsSupportInternal.hpp"

#include <string>

// The notification-area icon: the Windows counterpart of the Mac's menu bar
// extra. Its menu shows whether the app is ready or recording and today's
// totals, and offers Start or Stop Recording, Open, Settings and Quit. A
// hidden window of its own owns the icon, so opening the menu never brings
// the main window forward; a chosen command reaches the main window as
// `commandMessage` with the Command in wParam.
namespace jsti::tray {

constexpr UINT commandMessage = WM_APP + 22;
enum Command : UINT { none = 0, toggle = 1, open = 2, settings = 3, quit = 4 };

// UI thread. False when the shell has no notification area; the app works
// the same without it.
bool add(HWND owner, HICON idle, HICON recording);
void remove();
// recording: 0 idle, 1 recording, 2 transcribing. `summary` is the Sessions,
// Recording Time and Spend line; empty hides it.
void setState(int recording, const std::wstring &summary);
// The menu for a state; exposed for the self-test.
HMENU buildMenu(int recording, const std::wstring &summary);
bool selfTest(std::string &failure);

} // namespace jsti::tray
