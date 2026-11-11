// General > App visibility: taskbar, notification area and the staged sidebar/density/shell updates.
#include "WindowsWindowInternal.hpp"

namespace jsti_window {

int configureShell(ShellDelivery &delivery, HWND window, int visibility, int compact) {
    if (visibility < shellBoth || visibility > shellTaskbarOnly || (compact != 0 && compact != 1)) return -1;
    auto update = std::make_unique<ShellPresentation>();
    update->visibility = visibility;
    update->compact = compact != 0;
    return delivery.stage(window, std::move(update));
}

int configureVisualDensity(DensityDelivery &delivery, HWND window, JSTIVisualDensity density) {
    if ((density.compact != 0 && density.compact != 1) ||
        density.minimum_row_height < 30 || density.minimum_row_height > 64) return -1;
    const int spacing[] = {density.page_padding, density.section_spacing, density.card_padding,
        density.content_spacing, density.inline_spacing, density.group_spacing};
    for (int value : spacing) if (value < 0 || value > 128) return -1;
    return delivery.stage(window, std::make_unique<JSTIVisualDensity>(density));
}

int configureSidebarShortcuts(SidebarDelivery &delivery, HWND window,
                             const JSTISidebarShortcut *bindings, size_t count, int showHints) {
    if (!bindings || count > 10 || (showHints != 0 && showHints != 1)) return -1;
    auto update = std::make_unique<SidebarBindings>();
    bool used[10]{};
    for (size_t index = 0; index < count; ++index) {
        const auto &binding = bindings[index];
        std::wstring hint;
        if (!binding.destination || binding.digit < 0 || binding.digit > 9 || used[binding.digit] ||
            !binding.hint || !jsti::wide(binding.hint, hint) ||
            hint != L"Ctrl+" + std::to_wstring(binding.digit)) return -1;
        used[binding.digit] = true;
        bool matched = false;
        for (int page = 0; page < pageCount; ++page) {
            if (std::strcmp(pageInfo[page].name, binding.destination) != 0) continue;
            if (update->digits[page] != -1) return -1;
            update->digits[page] = binding.digit;
            update->hints[page] = hint;
            matched = true;
            break;
        }
        if (!matched) return -1;
    }
    update->showHints = showHints != 0;
    return delivery.stage(window, std::move(update));
}

// UI thread only. General > App visibility as applied: `trayResident` while
// the window lives in the notification area with no taskbar button.
ShellPresentation shell;
HWND shellOwner = nullptr;
bool trayResident = false;

// The taskbar shows a button for every visible unowned top-level window, so a
// hidden owner removes it. The shell reads that rule only when a window is
// shown, so a visible window is hidden around the change. Without a
// notification-area icon the button stays, so the window is never unreachable.
void applyShell(HWND window) {
    jsti::tray::setCompact(shell.compact);
    const bool wantsIcon = shell.visibility != shellTaskbarOnly;
    if (wantsIcon && !jsti::tray::shown())
        jsti::tray::add(window, jsti::appIcon::smallHandle(), jsti::appIcon::recordingHandle());
    trayResident = shell.visibility == shellTrayOnly && jsti::tray::shown();
    if (trayResident && !shellOwner) {
        shellOwner = CreateWindowExW(WS_EX_TOOLWINDOW, L"STATIC", L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
            GetModuleHandleW(nullptr), nullptr);
        trayResident = shellOwner != nullptr;
    }
    const HWND owner = trayResident ? shellOwner : nullptr;
    if (reinterpret_cast<HWND>(GetWindowLongPtrW(window, GWLP_HWNDPARENT)) != owner) {
        const bool visible = IsWindowVisible(window) != FALSE;
        if (visible) ShowWindow(window, SW_HIDE);
        SetWindowLongPtrW(window, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner));
        // A minimised window in the notification area stays hidden until opened.
        if (visible && !(trayResident && IsIconic(window))) ShowWindow(window, SW_SHOWNA);
    }
    if (!wantsIcon && jsti::tray::shown()) jsti::tray::remove();
    if (!owner && shellOwner) {
        DestroyWindow(shellOwner);
        shellOwner = nullptr;
    }
}

void releaseShell() {
    trayResident = false;
    if (shellOwner) DestroyWindow(shellOwner);
    shellOwner = nullptr;
}
// A command chosen from the notification area's menu, or its icon clicked.
void trayCommand(HWND window, UINT command) {
    if (command == jsti::tray::toggle) { emitRecording(window); return; }
    if (command == jsti::tray::quit) { PostMessageW(window, WM_CLOSE, 0, 0); return; }
    if (command != jsti::tray::open && command != jsti::tray::settings) return;
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window);
    if (command == jsti::tray::settings) showPage(window, generalPage);
}
} // namespace jsti_window

int jsti_window_set_sidebar_shortcuts(const JSTISidebarShortcut *bindings, size_t count, int showHints) {
    int result = -1;
    try {
        std::lock_guard<std::mutex> lock(state.mutex);
        result = configureSidebarShortcuts(state.sidebarDelivery, state.window, bindings, count, showHints);
    } catch (const std::exception &) { return -1; }
    // The host sends these after every configuration change, including imports,
    // so action shortcuts are read again with them.
    if (result == 0) jsti_action_shortcuts_request_refresh();
    return result;
}

int jsti_window_set_visual_density(JSTIVisualDensity density) {
    try {
        std::lock_guard<std::mutex> lock(state.mutex);
        return configureVisualDensity(state.densityDelivery, state.window, density);
    } catch (const std::exception &) { return -1; }
}

int jsti_window_set_shell(int visibility, int compact) {
    try {
        std::lock_guard<std::mutex> lock(state.mutex);
        return configureShell(state.shellDelivery, state.window, visibility, compact);
    } catch (const std::exception &) { return -1; }
}
