#pragma once

#include "WindowsSupportInternal.hpp"

#include <string>
#include <vector>

// The desktop window's look: the Mac app's brand tokens (SpeakCore
// BrandColors), its card and hero shapes, and light or dark surfaces that
// follow Windows or the saved Appearance. Drawing uses GDI+ for anti-aliased
// shapes and GDI for ClearType text, straight onto the window's DC, so the
// PrintWindow snapshot captures exactly what is on screen.
namespace jsti::chrome {

struct Palette {
    COLORREF window, sidebar, header, card, field, fieldBorder, text, secondary, border, selection;
};

// 0 follows Windows (AppsUseLightTheme), 1 light, 2 dark.
void setAppearance(int appearance);
int appearance();
bool dark();
const Palette &palette();
// Native controls and the title bar in the current light or dark mode.
// Themed check box, radio and group box labels ignore WM_CTLCOLOR* text
// colours and stay black, so dark mode draws those unthemed and the parent's
// WM_CTLCOLORSTATIC colours apply. Owner-drawn buttons are left alone.
void themeControl(HWND control);
// A light or dark title bar.
void themeTitleBar(HWND window);
// The window's title bar and every child control.
void themeWindow(HWND window);
// Lets an ordinary dialog procedure follow the appearance: call it before
// handling `message` and return `result` when it returns true. It themes the
// title bar on WM_CREATE and each control as it is created, and everything
// again when Windows' app mode changes while the app follows Windows. In dark
// mode it paints the background and gives labels, check boxes and fields light
// text on dark surfaces; in light mode the system colours stay.
bool dialogMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam, LRESULT &result);

// Dialog plumbing shared by the native settings dialogs. Each dialog keeps its
// own controls, layout and messages; these are only the identical steps.
// Logical (96-DPI) pixels at the window's DPI.
int scale(HWND window, int value);
// The instance passed as CreateWindowExW's lpParam, bound on WM_NCCREATE.
template<typename Instance>
Instance *dialogInstance(HWND window, UINT message, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        auto instance = static_cast<Instance *>(reinterpret_cast<CREATESTRUCTW *>(lparam)->lpCreateParams);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(instance));
        return instance;
    }
    return reinterpret_cast<Instance *>(GetWindowLongPtrW(window, GWLP_USERDATA));
}
// WM_GETMINMAXINFO: the smallest frame around a client area of the given logical size.
void minimumTrackSize(HWND window, LPARAM lparam, int clientWidth, int clientHeight, DWORD style, DWORD exStyle);
// WM_DPICHANGED: moves the window to the bounds Windows suggests.
void applySuggestedBounds(HWND window, LPARAM lparam);
// The dialogs' body font: 10-point Segoe UI at the window's DPI, or nullptr.
HFONT dialogFont(HWND window);
// Gives `controls` a fresh dialogFont and frees the one in `font`, which it replaces.
// Keeps the current font when a new one cannot be created.
void refreshDialogFont(HWND window, const std::vector<HWND> &controls, HFONT &font);
// A visible child control at 1x1 for the dialog's layout to place; false when refused.
bool addControl(HWND parent, const wchar_t *type, const wchar_t *text, DWORD style, int id, DWORD exStyle = 0);
// Registers `className` once and opens a dialog of the given logical client size
// 40 logical pixels below and right of the owner's top-left corner, with
// `instance` as its lpParam. nullptr when the class or window cannot be created.
HWND createOwnedDialog(HWND owner, const wchar_t *className, WNDPROC procedure, const wchar_t *title,
                       int clientWidth, int clientHeight, DWORD style, DWORD exStyle, void *instance);
// WM_ACTIVATE: remembers the focused control on deactivation and restores it,
// or the control `fallback`, on activation.
void rememberFocus(HWND window, WPARAM wparam, HWND &focus, int fallback);

// GDI+ for the process; idempotent.
bool startup();

// Brand colours.
constexpr COLORREF accent = RGB(0xFF, 0x6B, 0x3D);
constexpr COLORREF accentWarm = RGB(0xFF, 0x9C, 0x4A);
constexpr COLORREF accentDeep = RGB(0xE3, 0x52, 0x2E);
constexpr COLORREF lagoon = RGB(0x1A, 0xAB, 0x99);
constexpr COLORREF green = RGB(0x26, 0xA2, 0x69);
constexpr COLORREF blue = RGB(0x35, 0x84, 0xE4);
constexpr COLORREF orange = RGB(0xE6, 0x61, 0x00);
constexpr COLORREF red = RGB(0xD9, 0x2A, 0x2A);

enum class Gradient { brand, voice, settings, record, recording };

// Shapes, in device pixels. `alpha` is 0-255.
void fillRound(HDC dc, const RECT &rect, int radius, COLORREF color, int alpha = 255);
void strokeRound(HDC dc, const RECT &rect, int radius, COLORREF color, int alpha, float width);
void fillGradient(HDC dc, const RECT &rect, int radius, Gradient gradient);
// A soft drop shadow under a rounded shape.
void shadow(HDC dc, const RECT &rect, int radius, COLORREF color, int spread);

// Fonts, cached per DPI. Glyphs come from Segoe Fluent Icons (Windows 11)
// or Segoe MDL2 Assets (Windows 10).
enum class Font { body, bodySemibold, caption, footnote, smallBold, title, heroTitle, heroSubtitle, chipValue,
                  pageTitle, mono, icon, iconLarge };
HFONT font(Font role, UINT dpi);
// Segoe UI Variable Text or Segoe UI; Segoe Fluent Icons or Segoe MDL2 Assets.
const wchar_t *textFace();
const wchar_t *iconFace();
void text(HDC dc, const std::wstring &value, RECT rect, Font role, UINT dpi, COLORREF color, UINT format);
// Height `value` needs at `width`, for wrapped text.
int measure(HDC dc, const std::wstring &value, int width, Font role, UINT dpi);
void glyph(HDC dc, wchar_t code, const RECT &rect, COLORREF color, UINT dpi, bool large = false);

// The app icon: an orange rounded square with five dark bars, drawn from
// Resources/Brand/AppIcon.svg's geometry.
void brandIcon(HDC dc, const RECT &rect);

// Mixes `over` onto `under` by `amount` (0-255 of `over`).
COLORREF mix(COLORREF under, COLORREF over, int amount);

} // namespace jsti::chrome
