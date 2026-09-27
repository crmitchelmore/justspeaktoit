#include "WindowsWindowChrome.hpp"

#include <algorithm>
#include <map>
#include <mutex>

// GDI+ expects min and max from the Windows headers, which NOMINMAX removes.
namespace Gdiplus {
using std::max;
using std::min;
} // namespace Gdiplus
#include <objidl.h>
#include <gdiplus.h>

namespace jsti::chrome {
namespace {

std::mutex fontLock;
std::map<std::pair<int, UINT>, HFONT> fonts;
int chosenAppearance = 0;
ULONG_PTR gdiplusToken = 0;

bool systemUsesDark() {
    DWORD light = 1, size = sizeof(light);
    const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", L"AppsUseLightTheme",
        RRF_RT_REG_DWORD, nullptr, &light, &size);
    return status == ERROR_SUCCESS && light == 0;
}

const Palette lightPalette{
    RGB(0xF6, 0xF6, 0xF7), RGB(0xEC, 0xEC, 0xEE), RGB(0xF6, 0xF6, 0xF7), RGB(0xFF, 0xFF, 0xFF),
    RGB(0xF2, 0xF2, 0xF4), RGB(0xDD, 0xDD, 0xE1), RGB(0x1F, 0x1F, 0x22), RGB(0x6B, 0x6B, 0x72),
    RGB(0xF4, 0xD6, 0xCC), RGB(0xFB, 0xE3, 0xDA)};
const Palette darkPalette{
    RGB(0x1E, 0x1E, 0x20), RGB(0x26, 0x26, 0x29), RGB(0x1E, 0x1E, 0x20), RGB(0x2B, 0x2B, 0x2E),
    RGB(0x36, 0x36, 0x3A), RGB(0x46, 0x46, 0x4B), RGB(0xF2, 0xF2, 0xF3), RGB(0xA1, 0xA1, 0xA8),
    RGB(0x5A, 0x38, 0x2E), RGB(0x4A, 0x30, 0x2A)};

Gdiplus::Color color(COLORREF value, int alpha = 255) {
    return Gdiplus::Color(static_cast<BYTE>(alpha), GetRValue(value), GetGValue(value), GetBValue(value));
}

void roundedPath(Gdiplus::GraphicsPath &path, const RECT &rect, int radius) {
    const float x = static_cast<float>(rect.left), y = static_cast<float>(rect.top);
    const float width = static_cast<float>(rect.right - rect.left), height = static_cast<float>(rect.bottom - rect.top);
    const float diameter = std::min({2.0f * radius, width, height});
    if (diameter <= 1.0f) {
        path.AddRectangle(Gdiplus::RectF(x, y, width, height));
        return;
    }
    path.AddArc(x, y, diameter, diameter, 180, 90);
    path.AddArc(x + width - diameter, y, diameter, diameter, 270, 90);
    path.AddArc(x + width - diameter, y + height - diameter, diameter, diameter, 0, 90);
    path.AddArc(x, y + height - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
}

struct Canvas {
    Gdiplus::Graphics graphics;
    explicit Canvas(HDC dc) : graphics(dc) {
        graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    }
};

} // namespace

const wchar_t *iconFace() {
    static const wchar_t *face = [] {
        HDC screen = GetDC(nullptr);
        LOGFONTW query{};
        query.lfCharSet = DEFAULT_CHARSET;
        wcscpy_s(query.lfFaceName, L"Segoe Fluent Icons");
        bool found = false;
        EnumFontFamiliesExW(screen, &query, [](const LOGFONTW *, const TEXTMETRICW *, DWORD, LPARAM found) {
            *reinterpret_cast<bool *>(found) = true;
            return 0;
        }, reinterpret_cast<LPARAM>(&found), 0);
        ReleaseDC(nullptr, screen);
        return found ? L"Segoe Fluent Icons" : L"Segoe MDL2 Assets";
    }();
    return face;
}

const wchar_t *textFace() {
    static const wchar_t *face = [] {
        HDC screen = GetDC(nullptr);
        LOGFONTW query{};
        query.lfCharSet = DEFAULT_CHARSET;
        wcscpy_s(query.lfFaceName, L"Segoe UI Variable Text");
        bool found = false;
        EnumFontFamiliesExW(screen, &query, [](const LOGFONTW *, const TEXTMETRICW *, DWORD, LPARAM found) {
            *reinterpret_cast<bool *>(found) = true;
            return 0;
        }, reinterpret_cast<LPARAM>(&found), 0);
        ReleaseDC(nullptr, screen);
        return found ? L"Segoe UI Variable Text" : L"Segoe UI";
    }();
    return face;
}

bool startup() {
    if (gdiplusToken) return true;
    Gdiplus::GdiplusStartupInput input;
    return Gdiplus::GdiplusStartup(&gdiplusToken, &input, nullptr) == Gdiplus::Ok;
}

void setAppearance(int value) { chosenAppearance = value >= 0 && value <= 2 ? value : 0; }
int appearance() { return chosenAppearance; }
bool dark() { return chosenAppearance == 2 || (chosenAppearance == 0 && systemUsesDark()); }
const Palette &palette() { return dark() ? darkPalette : lightPalette; }

COLORREF mix(COLORREF under, COLORREF over, int amount) {
    auto channel = [&](int a, int b) { return static_cast<BYTE>((a * (255 - amount) + b * amount) / 255); };
    return RGB(channel(GetRValue(under), GetRValue(over)), channel(GetGValue(under), GetGValue(over)),
               channel(GetBValue(under), GetBValue(over)));
}

void fillRound(HDC dc, const RECT &rect, int radius, COLORREF fill, int alpha) {
    if (rect.right <= rect.left || rect.bottom <= rect.top) return;
    Canvas canvas(dc);
    Gdiplus::GraphicsPath path;
    roundedPath(path, rect, radius);
    Gdiplus::SolidBrush brush(color(fill, alpha));
    canvas.graphics.FillPath(&brush, &path);
}

void strokeRound(HDC dc, const RECT &rect, int radius, COLORREF stroke, int alpha, float width) {
    if (rect.right <= rect.left || rect.bottom <= rect.top) return;
    Canvas canvas(dc);
    Gdiplus::GraphicsPath path;
    RECT inset = rect;
    const int half = static_cast<int>(width / 2);
    InflateRect(&inset, -half, -half);
    roundedPath(path, inset, radius);
    Gdiplus::Pen pen(color(stroke, alpha), width);
    canvas.graphics.DrawPath(&pen, &path);
}

void fillGradient(HDC dc, const RECT &rect, int radius, Gradient gradient) {
    if (rect.right <= rect.left || rect.bottom <= rect.top) return;
    COLORREF from = accentDeep, to = accentWarm;
    float angle = 25.0f;
    switch (gradient) {
    case Gradient::brand: break;
    case Gradient::voice: from = RGB(0x1F, 0x9D, 0x55); to = RGB(0x4B, 0xCF, 0xA0); break;
    case Gradient::settings: from = RGB(0xF0, 0x7A, 0x1A); to = RGB(0xF7, 0xAE, 0x5A); break;
    case Gradient::record: from = RGB(0x2D, 0x8C, 0xFF); to = RGB(0x0A, 0x6C, 0xFF); angle = 90.0f; break;
    case Gradient::recording: from = RGB(0xFF, 0x5A, 0x5A); to = red; angle = 90.0f; break;
    }
    Canvas canvas(dc);
    Gdiplus::GraphicsPath path;
    roundedPath(path, rect, radius);
    const Gdiplus::RectF bounds(static_cast<float>(rect.left) - 1, static_cast<float>(rect.top) - 1,
                                static_cast<float>(rect.right - rect.left) + 2,
                                static_cast<float>(rect.bottom - rect.top) + 2);
    Gdiplus::LinearGradientBrush brush(bounds, color(from), color(to), angle, TRUE);
    canvas.graphics.FillPath(&brush, &path);
}

void shadow(HDC dc, const RECT &rect, int radius, COLORREF tint, int spread) {
    if (spread <= 0) return;
    // Concentric translucent layers approximate a blur without a bitmap.
    for (int step = spread; step > 0; step -= std::max(1, spread / 6)) {
        RECT layer = rect;
        InflateRect(&layer, step / 2, step / 2);
        OffsetRect(&layer, 0, step / 2);
        fillRound(dc, layer, radius + step / 2, tint, std::max(2, 18 - step));
    }
}

HFONT font(Font role, UINT dpi) {
    std::lock_guard<std::mutex> lock(fontLock);
    const auto key = std::make_pair(static_cast<int>(role), dpi);
    const auto found = fonts.find(key);
    if (found != fonts.end()) return found->second;
    int points = 10, weight = FW_NORMAL;
    const wchar_t *face = textFace();
    switch (role) {
    case Font::body: break;
    case Font::bodySemibold: weight = FW_SEMIBOLD; break;
    case Font::caption: points = 9; break;
    case Font::footnote: points = 8; break;
    case Font::smallBold: points = 7; weight = FW_BOLD; break;
    case Font::title: points = 12; weight = FW_SEMIBOLD; break;
    case Font::heroTitle: points = 21; weight = FW_BOLD; break;
    case Font::heroSubtitle: points = 10; weight = FW_SEMIBOLD; break;
    case Font::chipValue: points = 14; weight = FW_BOLD; break;
    case Font::pageTitle: points = 11; weight = FW_SEMIBOLD; break;
    case Font::mono: points = 10; face = L"Cascadia Mono"; break;
    case Font::icon: points = 11; face = iconFace(); break;
    case Font::iconLarge: points = 14; face = iconFace(); break;
    }
    HFONT created = CreateFontW(-MulDiv(points, static_cast<int>(dpi), 72), 0, 0, 0, weight, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, face);
    if (role == Font::mono && created) {
        // Consolas where Cascadia Mono is not installed.
        LOGFONTW actual{};
        GetObjectW(created, sizeof(actual), &actual);
        HDC screen = GetDC(nullptr);
        HGDIOBJ previous = SelectObject(screen, created);
        wchar_t chosen[LF_FACESIZE] = {};
        GetTextFaceW(screen, LF_FACESIZE, chosen);
        SelectObject(screen, previous);
        ReleaseDC(nullptr, screen);
        if (wcscmp(chosen, L"Cascadia Mono") != 0) {
            DeleteObject(created);
            created = CreateFontW(-MulDiv(points, static_cast<int>(dpi), 72), 0, 0, 0, weight, FALSE, FALSE, FALSE,
                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH, L"Consolas");
        }
    }
    fonts[key] = created;
    return created;
}

void text(HDC dc, const std::wstring &value, RECT rect, Font role, UINT dpi, COLORREF shade, UINT format) {
    HGDIOBJ previous = SelectObject(dc, font(role, dpi));
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, shade);
    DrawTextW(dc, value.c_str(), static_cast<int>(value.size()), &rect, format);
    SelectObject(dc, previous);
}

int measure(HDC dc, const std::wstring &value, int width, Font role, UINT dpi) {
    RECT rect{0, 0, width, 0};
    HGDIOBJ previous = SelectObject(dc, font(role, dpi));
    DrawTextW(dc, value.c_str(), static_cast<int>(value.size()), &rect, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, previous);
    return rect.bottom - rect.top;
}

void glyph(HDC dc, wchar_t code, const RECT &rect, COLORREF shade, UINT dpi, bool large) {
    text(dc, std::wstring(1, code), rect, large ? Font::iconLarge : Font::icon, dpi, shade,
         DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
}

void brandIcon(HDC dc, const RECT &rect) {
    const int size = std::min(rect.right - rect.left, rect.bottom - rect.top);
    const float scale = size / 1024.0f;
    const float left = static_cast<float>(rect.left), top = static_cast<float>(rect.top);
    auto scaled = [&](float x, float y, float width, float height) {
        return RECT{static_cast<LONG>(left + x * scale), static_cast<LONG>(top + y * scale),
                    static_cast<LONG>(left + (x + width) * scale), static_cast<LONG>(top + (y + height) * scale)};
    };
    Canvas canvas(dc);
    Gdiplus::GraphicsPath square;
    roundedPath(square, scaled(0, 0, 1024, 1024), static_cast<int>(224 * scale));
    Gdiplus::LinearGradientBrush surface(Gdiplus::PointF(left, top), Gdiplus::PointF(left, top + size),
                                         color(accent), color(accentWarm));
    canvas.graphics.FillPath(&surface, &square);
    Gdiplus::SolidBrush bar(color(RGB(0x18, 0x1B, 0x1D)));
    const float bars[5][2] = {{224, 408}, {348, 328}, {472, 240}, {596, 328}, {720, 408}};
    for (const auto &entry : bars) {
        Gdiplus::GraphicsPath path;
        roundedPath(path, scaled(entry[0], entry[1], 80, 1024 - 2 * entry[1]), static_cast<int>(40 * scale));
        canvas.graphics.FillPath(&bar, &path);
    }
}

} // namespace jsti::chrome
