#include "WindowsWindowChrome.hpp"

#include <commctrl.h>
#include <dwmapi.h>
#include <uxtheme.h>

#include <algorithm>
#include <cwchar>
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
std::mutex brushLock;
std::map<COLORREF, HBRUSH> brushes;
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

// Palette brushes live for the process, so WM_CTLCOLOR* can return them.
HBRUSH solidBrush(COLORREF value) {
    std::lock_guard<std::mutex> lock(brushLock);
    const auto found = brushes.find(value);
    if (found != brushes.end()) return found->second;
    HBRUSH created = CreateSolidBrush(value);
    if (created) brushes[value] = created;
    return created;
}

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

void themeControl(HWND control) {
    if (!control) return;
    const bool useDark = dark();
    wchar_t kind[32] = {};
    GetClassNameW(control, kind, 32);
    if (_wcsicmp(kind, L"COMBOBOX") == 0) {
        SetWindowTheme(control, useDark ? L"DarkMode_CFD" : nullptr, nullptr);
    } else if (_wcsicmp(kind, L"BUTTON") == 0) {
        switch (static_cast<DWORD>(GetWindowLongPtrW(control, GWL_STYLE)) & BS_TYPEMASK) {
        case BS_OWNERDRAW: break;
        case BS_CHECKBOX: case BS_AUTOCHECKBOX: case BS_3STATE: case BS_AUTO3STATE:
        case BS_RADIOBUTTON: case BS_AUTORADIOBUTTON: case BS_GROUPBOX:
            SetWindowTheme(control, useDark ? L"" : nullptr, useDark ? L"" : nullptr);
            break;
        default: SetWindowTheme(control, useDark ? L"DarkMode_Explorer" : nullptr, nullptr); break;
        }
    } else if (_wcsicmp(kind, WC_LISTVIEWW) == 0) {
        // List views ignore WM_CTLCOLOR*; their colours are set on the control.
        SetWindowTheme(control, useDark ? L"DarkMode_Explorer" : nullptr, nullptr);
        const COLORREF back = useDark ? palette().field : GetSysColor(COLOR_WINDOW);
        SendMessageW(control, LVM_SETBKCOLOR, 0, static_cast<LPARAM>(back));
        SendMessageW(control, LVM_SETTEXTBKCOLOR, 0, static_cast<LPARAM>(back));
        SendMessageW(control, LVM_SETTEXTCOLOR, 0,
            static_cast<LPARAM>(useDark ? palette().text : GetSysColor(COLOR_WINDOWTEXT)));
        const HWND header = reinterpret_cast<HWND>(SendMessageW(control, LVM_GETHEADER, 0, 0));
        if (header) SetWindowTheme(header, useDark ? L"DarkMode_ItemsView" : nullptr, nullptr);
    } else if (_wcsicmp(kind, WC_HEADERW) == 0) {
        SetWindowTheme(control, useDark ? L"DarkMode_ItemsView" : nullptr, nullptr);
    } else if (_wcsicmp(kind, L"EDIT") == 0 || _wcsicmp(kind, L"LISTBOX") == 0 ||
               _wcsicmp(kind, WC_TREEVIEWW) == 0 || _wcsicmp(kind, L"ScrollBar") == 0) {
        SetWindowTheme(control, useDark ? L"DarkMode_Explorer" : L"Explorer", nullptr);
    }
}

void themeTitleBar(HWND window) {
    if (!window) return;
    const BOOL useDark = dark() ? TRUE : FALSE;
    // DWMWA_USE_IMMERSIVE_DARK_MODE is 20 from Windows 10 20H1 and 19 before it.
    if (FAILED(DwmSetWindowAttribute(window, 20, &useDark, sizeof(useDark)))) {
        DwmSetWindowAttribute(window, 19, &useDark, sizeof(useDark));
    }
}

void themeWindow(HWND window) {
    if (!window) return;
    themeTitleBar(window);
    EnumChildWindows(window, [](HWND control, LPARAM) -> BOOL {
        themeControl(control);
        return TRUE;
    }, 0);
}

int scale(HWND window, int value) { return MulDiv(value, static_cast<int>(GetDpiForWindow(window)), 96); }

void minimumTrackSize(HWND window, LPARAM lparam, int clientWidth, int clientHeight, DWORD style, DWORD exStyle) {
    RECT frame{0, 0, scale(window, clientWidth), scale(window, clientHeight)};
    AdjustWindowRectExForDpi(&frame, style, FALSE, exStyle, GetDpiForWindow(window));
    reinterpret_cast<MINMAXINFO *>(lparam)->ptMinTrackSize = {frame.right - frame.left, frame.bottom - frame.top};
}

void applySuggestedBounds(HWND window, LPARAM lparam) {
    const RECT *bounds = reinterpret_cast<RECT *>(lparam);
    SetWindowPos(window, nullptr, bounds->left, bounds->top, bounds->right - bounds->left,
        bounds->bottom - bounds->top, SWP_NOZORDER | SWP_NOACTIVATE);
}

void rememberFocus(HWND window, WPARAM wparam, HWND &focus, int fallback) {
    if (LOWORD(wparam) == WA_INACTIVE) { focus = GetFocus(); return; }
    SetFocus(focus && IsChild(window, focus) ? focus : GetDlgItem(window, fallback));
}

bool dialogMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam, LRESULT &result) {
    switch (message) {
    case WM_CREATE: themeTitleBar(window); return false;
    case WM_PARENTNOTIFY:
        if (LOWORD(wparam) == WM_CREATE) themeControl(reinterpret_cast<HWND>(lparam));
        return false;
    case WM_SETTINGCHANGE:
        if (lparam && appearance() == 0 &&
            wcscmp(reinterpret_cast<const wchar_t *>(lparam), L"ImmersiveColorSet") == 0) {
            themeWindow(window);
            RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_FRAME);
        }
        return false;
    case WM_ERASEBKGND: {
        if (!dark()) return false;
        RECT client{};
        GetClientRect(window, &client);
        FillRect(reinterpret_cast<HDC>(wparam), &client, solidBrush(palette().window));
        result = 1;
        return true;
    }
    case WM_CTLCOLORDLG:
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX: {
        if (!dark()) return false;
        const Palette &colours = palette();
        // Editable fields and lists sit on the field colour; labels, check
        // boxes and read-only text on the window's surface.
        const COLORREF surface = message == WM_CTLCOLOREDIT || message == WM_CTLCOLORLISTBOX
            ? colours.field : colours.window;
        HDC dc = reinterpret_cast<HDC>(wparam);
        SetTextColor(dc, colours.text);
        SetBkColor(dc, surface);
        result = reinterpret_cast<LRESULT>(solidBrush(surface));
        return true;
    }
    default: return false;
    }
}

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
    HICON icon = reinterpret_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(101),
                                                   IMAGE_ICON, size, size, LR_DEFAULTCOLOR));
    if (icon) {
        DrawIconEx(dc, rect.left, rect.top, icon, size, size, 0, nullptr, DI_NORMAL);
        DestroyIcon(icon);
    }
}

} // namespace jsti::chrome
