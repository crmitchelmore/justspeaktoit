#pragma once
#include "WindowsSupportInternal.hpp"
#include <functional>

void jsti_show_history_filters(HWND owner, std::function<void(const std::string &)> apply);
bool jsti_history_filters_message(MSG *message);
void jsti_history_filters_enabled(bool enabled);
std::wstring jsti_history_filters_label();
bool jsti_history_filters_active();
bool jsti_history_filters_self_test(HWND owner, std::string &error);
HWND jsti_history_filters_window();
void jsti_history_filters_refresh_theme();
