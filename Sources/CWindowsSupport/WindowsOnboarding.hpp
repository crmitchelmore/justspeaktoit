#pragma once

#include "WindowsSupportInternal.hpp"

// The modeless first-run guide and Permissions windows (Onboarding.h), owned
// by the main window. The main message loop routes their keyboard navigation.
void jsti_show_guide(HWND owner);
bool jsti_guide_message(MSG *message);
void jsti_show_permissions(HWND owner);
bool jsti_permissions_message(MSG *message);
