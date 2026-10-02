#pragma once

#include "WindowsSupportInternal.hpp"

#include <string>

// General › Launch at login, as the shared DesktopLoginItemState. The portable
// app registers `"<exe>" --background` as HKCU\...\Run\JustSpeakToIt. Turning
// it off in Task Manager or Settings › Apps › Startup leaves Explorer's
// StartupApproved\Run entry with an odd first byte, which reads as off here,
// and the app's own switch turning it back on removes that entry. The MSIX app
// declares a windows.startupTask with the same argument instead (its registry
// writes would not reach Explorer), and the StartupTask API reports its state,
// including a user's or a policy's decision the app cannot override.
namespace jsti::login {

enum State : int { off = 0, on = 1, offBySystem = 2, onBySystem = 3, unavailable = 4 };

constexpr wchar_t launchArgument[] = L"--background";
constexpr wchar_t runValue[] = L"JustSpeakToIt";

// True when this process's command line carries launchArgument.
bool launchedAtLogin();
bool packaged();
State state();
// Returns the state reached; false with `failure` when the system refused.
bool set(bool enabled, State &reached, std::string &failure);
bool selfTest(std::string &failure);

// The Run value `name` for `command`, so the self-test can use its own name.
State registryState(const wchar_t *name);
bool setRegistry(const wchar_t *name, const std::wstring &command, bool enabled, std::string &failure);

// The packaged startup task (WindowsStartupTask.cpp), declared with this id in
// AppxManifest.xml.in. Each call runs on a thread of its own in the
// multithreaded apartment and waits at most `timeout` for the system.
namespace task {
constexpr wchar_t identifier[] = L"JustSpeakToIt";
bool state(State &state, std::string &failure);
bool set(bool enabled, State &reached, std::string &failure);
} // namespace task

} // namespace jsti::login
