#pragma once

#include "WindowsSupportInternal.hpp"

#include <string>

// The recording HUD: the Mac's bottom-centre dictation card, as a layered,
// topmost, click-through tool window that never takes focus, so text
// insertion still reaches the field the user was typing in. Phases and
// wording come from the shared DesktopHUDState; this draws them.
namespace jsti::hud {

// Any thread. Keeps only the latest state; returns false for invalid input.
bool stage(int phase, std::wstring headline, std::wstring subheadline, std::wstring live);
// UI thread: shows the latest staged state, creating the window on first use.
void apply();
// UI thread: redraws after an appearance change.
void refresh();
// UI thread: destroys the window with the app.
void destroy();
// UI thread: saves the HUD as a BMP over the window background, for the
// screenshot tour. Returns false with `error` when nothing can be drawn.
bool saveSnapshot(const std::wstring &path, std::string &error);
// UI thread: checks the window never activates, stays click-through and
// topmost, sits at the bottom centre of a work area and hides again.
bool selfTest(std::string &failure);

} // namespace jsti::hud
