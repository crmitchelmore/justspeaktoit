#pragma once
#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <string>

// Native preview and confirmation for restoring a Mac-compatible ZIP backup.
// The window owns posting; this unit owns the single pending confirmation.
namespace jsti::migrationRestore {
constexpr UINT message = WM_APP + 47;

// Stages one confirmation. Fails while another confirmation is pending.
bool stage(const std::string &token, std::wstring text, bool offersReplace);
void clear();
// Shows the staged preview when `available`, then answers its token exactly once:
// 0 cancels, 1 merges, 2 replaces app profiles. Nothing is written before the answer.
void present(HWND window, bool available, JSTIWindowCallback callback, void *context);
// Returns the chosen ZIP as UTF-8, or empty when cancelled; `failure` explains a failed chooser.
std::string choose(HWND window, std::string &failure);
}
