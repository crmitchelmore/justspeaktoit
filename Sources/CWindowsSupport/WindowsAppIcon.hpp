#pragma once

#include "WindowsSupportInternal.hpp"
#include <string>

namespace jsti::appIcon {
// Owned icons; refresh before releasing the handles currently used by the shell.
bool refresh(HWND window, UINT dpi, std::string &failure);
HICON largeHandle();
HICON smallHandle();
HICON recordingHandle();
void destroy();
bool selfTest(HWND window, std::string &failure);
}
