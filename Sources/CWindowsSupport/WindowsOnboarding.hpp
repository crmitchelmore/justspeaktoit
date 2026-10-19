#pragma once

#include "WindowsSupportInternal.hpp"

// The modeless first-run guide, Permissions and Troubleshooting windows, owned
// by the main window. The main message loop routes their keyboard navigation.
void jsti_show_guide(HWND owner);
bool jsti_guide_message(MSG *message);
void jsti_show_permissions(HWND owner);
bool jsti_permissions_message(MSG *message);
void jsti_show_troubleshooting(HWND owner);
bool jsti_troubleshooting_self_test(HWND owner);
