#pragma once

#include "WindowsSupportInternal.hpp"

#include <string>

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
