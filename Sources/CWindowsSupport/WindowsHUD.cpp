#include "WindowsHUD.hpp"
#include "WindowsWindowChrome.hpp"

#include <cmath>
#include <cstdio>
#include <mutex>
#include <vector>

// GDI+ expects min and max from the Windows headers, which NOMINMAX removes.
namespace Gdiplus {
using std::max;
using std::min;
} // namespace Gdiplus
#include <objidl.h>
#include <gdiplus.h>
#include <shellscalingapi.h>

namespace jsti::hud {
namespace {

// DesktopHUDState.Phase raw values.
enum Phase { hidden = 0, recording, transcribing, postProcessing, delivering, success, failure, phaseCount };

struct Content {
    int phase = hidden;
    std::wstring headline, subheadline, live;
    bool operator==(const Content &other) const {
        return phase == other.phase && headline == other.headline && subheadline == other.subheadline &&
               live == other.live;
    }
};

constexpr wchar_t className[] = L"JSTIRecordingHUD";
constexpr UINT_PTR tickTimer = 1, hideTimer = 2;
constexpr UINT tickMilliseconds = 33;
// As on the Mac: a finished dictation stays up 2.4 s, a failure 6 s.
constexpr UINT successMilliseconds = 2400, failureMilliseconds = 6000;
// Room around the card for its shadow, in DIPs.
constexpr float margin = 18.0f;

std::mutex stagedLock;
Content staged;

// UI thread only.
HWND window = nullptr;
bool registered = false;
Content shown;
ULONGLONG phaseStarted = 0;
float meter = 0;

bool terminal(int phase) { return phase == success || phase == failure; }

COLORREF phaseColor(int phase) {
    switch (phase) {
    case recording: case failure: return chrome::red;
    case transcribing: return chrome::lagoon;
    case postProcessing: return chrome::accent;
    default: return chrome::green;
    }
}

wchar_t phaseGlyph(int phase) {
    switch (phase) {
    case recording: return 0xE720;      // Microphone
    case transcribing: return 0xE895;   // Sync
    case postProcessing: return 0xE735; // FavoriteStarFill
    case delivering: return 0xE724;     // Send
    case success: return 0xE73E;        // CheckMark
    default: return 0xE7BA;             // Warning
    }
}

Gdiplus::Color color(COLORREF value, int alpha = 255) {
    return Gdiplus::Color(static_cast<BYTE>(std::clamp(alpha, 0, 255)), GetRValue(value), GetGValue(value),
                          GetBValue(value));
}

void roundedPath(Gdiplus::GraphicsPath &path, Gdiplus::RectF rect, float radius) {
    const float diameter = std::min({2.0f * radius, rect.Width, rect.Height});
    path.AddArc(rect.X, rect.Y, diameter, diameter, 180, 90);
    path.AddArc(rect.X + rect.Width - diameter, rect.Y, diameter, diameter, 270, 90);
    path.AddArc(rect.X + rect.Width - diameter, rect.Y + rect.Height - diameter, diameter, diameter, 0, 90);
    path.AddArc(rect.X, rect.Y + rect.Height - diameter, diameter, diameter, 90, 90);
    path.CloseFigure();
}

std::wstring clockText(ULONGLONG milliseconds) {
    const unsigned long long hundredthsTotal = (milliseconds + 5) / 10;
    const unsigned minutes = static_cast<unsigned>(hundredthsTotal / 6000);
    const unsigned seconds = static_cast<unsigned>((hundredthsTotal / 100) % 60);
    const unsigned hundredths = static_cast<unsigned>(hundredthsTotal % 100);
    wchar_t text[32];
    if (minutes > 0) swprintf(text, 32, L"%02u:%02u.%02u", minutes, seconds, hundredths);
    else swprintf(text, 32, L"%02u.%02us", seconds, hundredths);
    return text;
}

// GDI+ draws nothing with a missing family, so each falls back: Segoe UI to
// the system sans serif, and Segoe UI Semibold to bold.
struct Fonts {
    Gdiplus::FontFamily segoe{L"Segoe UI"}, segoeSemibold{L"Segoe UI Semibold"}, iconFamily{chrome::iconFace()};
    const Gdiplus::FontFamily &regular() const {
        return segoe.IsAvailable() ? segoe : *Gdiplus::FontFamily::GenericSansSerif();
    }
    const Gdiplus::FontFamily &strong() const { return segoeSemibold.IsAvailable() ? segoeSemibold : regular(); }
    INT strongStyle() const { return segoeSemibold.IsAvailable() ? Gdiplus::FontStyleRegular : Gdiplus::FontStyleBold; }
    const Gdiplus::FontFamily &icons() const { return iconFamily.IsAvailable() ? iconFamily : regular(); }
};

// Where each part of the card goes, for one content and DPI.
struct Layout {
    float scale = 1;
    int width = 0, height = 0;
    Gdiplus::RectF card, glyph, headline, subheadline, meter, clock, liveBox, live;
    std::wstring liveShown;
    bool showsMeter = false, showsClock = false, showsLive = false;
};

float measure(Gdiplus::Graphics &graphics, const std::wstring &text, const Gdiplus::Font &font, float width,
              const Gdiplus::StringFormat &format) {
    Gdiplus::RectF bounds;
    graphics.MeasureString(text.c_str(), static_cast<INT>(text.size()), &font, Gdiplus::RectF(0, 0, width, 10000),
                           &format, &bounds);
    return std::ceil(bounds.Height);
}

Layout layoutFor(const Content &content, UINT dpi) {
    Layout layout;
    layout.scale = static_cast<float>(dpi) / 96.0f;
    const float s = layout.scale;
    layout.showsLive = content.phase == recording && !content.live.empty();
    layout.showsMeter = content.phase == recording;
    layout.showsClock = !terminal(content.phase);
    const float cardWidth = (layout.showsLive ? 460.0f : 340.0f) * s;
    const float inner = cardWidth - 48.0f * s;
    Fonts fonts;
    const Gdiplus::Font headline(&fonts.strong(), 15.0f * s, fonts.strongStyle(), Gdiplus::UnitPixel);
    const Gdiplus::Font detail(&fonts.regular(), 12.5f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    const Gdiplus::Font live(&fonts.regular(), 13.0f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Bitmap scratch(1, 1, PixelFormat32bppPARGB);
    Gdiplus::Graphics graphics(&scratch);
    Gdiplus::StringFormat centred;
    centred.SetAlignment(Gdiplus::StringAlignmentCenter);
    const float left = margin * s, top = (margin - 6.0f) * s;
    float y = top + 16.0f * s;
    layout.glyph = Gdiplus::RectF(left + (cardWidth - 40.0f * s) / 2, y, 40.0f * s, 40.0f * s);
    y += 40.0f * s + 12.0f * s;
    const float headlineHeight = measure(graphics, content.headline.empty() ? L" " : content.headline, headline,
                                         inner, centred);
    layout.headline = Gdiplus::RectF(left + 24.0f * s, y, inner, headlineHeight);
    y += headlineHeight;
    if (!content.subheadline.empty()) {
        const float lineHeight = measure(graphics, L" ", detail, inner, centred);
        const float height = std::min(measure(graphics, content.subheadline, detail, inner, centred), 3 * lineHeight);
        y += 4.0f * s;
        layout.subheadline = Gdiplus::RectF(left + 24.0f * s, y, inner, height);
        y += height;
    }
    if (layout.showsMeter) {
        y += 10.0f * s;
        layout.meter = Gdiplus::RectF(left + (cardWidth - 100.0f * s) / 2, y, 100.0f * s, 4.0f * s);
        y += 4.0f * s;
    }
    if (layout.showsClock) {
        y += 8.0f * s;
        const float height = measure(graphics, L"00.00s", detail, inner, centred);
        layout.clock = Gdiplus::RectF(left + 24.0f * s, y, inner, height);
        y += height;
    }
    if (layout.showsLive) {
        // Two lines of the latest words, dropping earlier ones from the front.
        Gdiplus::StringFormat leading;
        const float boxInner = inner - 20.0f * s;
        const float twoLines = 2 * measure(graphics, L" ", live, boxInner, leading) + 1;
        std::wstring text = content.live;
        bool trimmed = false;
        while (text.size() > 1 && measure(graphics, (trimmed ? L"…" : L"") + text, live, boxInner, leading) > twoLines) {
            const size_t space = text.find(L' ', 1);
            text = space == std::wstring::npos || space + 1 >= text.size() ? text.substr(text.size() / 2)
                                                                          : text.substr(space + 1);
            trimmed = true;
        }
        layout.liveShown = (trimmed ? L"…" : L"") + text;
        y += 12.0f * s;
        const float height = measure(graphics, layout.liveShown, live, boxInner, leading);
        layout.liveBox = Gdiplus::RectF(left + 24.0f * s, y, inner, height + 20.0f * s);
        layout.live = Gdiplus::RectF(left + 34.0f * s, y + 10.0f * s, boxInner, height);
        y += height + 20.0f * s;
    }
    y += 16.0f * s;
    layout.card = Gdiplus::RectF(left, top, cardWidth, y - top);
    layout.width = static_cast<int>(std::ceil(cardWidth + 2 * margin * s));
    layout.height = static_cast<int>(std::ceil(y + margin * s));
    return layout;
}

// A top-down 32-bit premultiplied DIB for UpdateLayeredWindow.
struct Surface {
    HDC dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    uint32_t *pixels = nullptr;
    int width = 0, height = 0;
    Surface(int width, int height) : width(width), height(height) {
        BITMAPINFO info{};
        info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        dc = CreateCompatibleDC(nullptr);
        void *bits = nullptr;
        bitmap = dc ? CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0) : nullptr;
        if (bitmap) {
            pixels = static_cast<uint32_t *>(bits);
            std::fill_n(pixels, static_cast<size_t>(width) * height, 0u);
            previous = SelectObject(dc, bitmap);
        }
    }
    ~Surface() {
        if (previous) SelectObject(dc, previous);
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
    }
    Surface(const Surface &) = delete;
    Surface &operator=(const Surface &) = delete;
    bool valid() const { return pixels != nullptr; }
};

void draw(Surface &surface, const Layout &layout, const Content &content, ULONGLONG elapsed, float level) {
    Gdiplus::Bitmap bitmap(surface.width, surface.height, surface.width * 4, PixelFormat32bppPARGB,
                           reinterpret_cast<BYTE *>(surface.pixels));
    Gdiplus::Graphics graphics(&bitmap);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    const float s = layout.scale;
    const bool dark = chrome::dark();
    const auto &palette = chrome::palette();
    const COLORREF tint = phaseColor(content.phase);

    // Shadow: stacked translucent layers under the card.
    for (int step = 12; step > 0; step -= 2) {
        Gdiplus::GraphicsPath path;
        Gdiplus::RectF layer = layout.card;
        layer.Inflate(step * 0.5f * s, step * 0.5f * s);
        layer.Offset(0, (6.0f + step * 0.5f) * s);
        roundedPath(path, layer, (20.0f + step * 0.5f) * s);
        Gdiplus::SolidBrush brush(color(RGB(0, 0, 0), dark ? 16 : 7));
        graphics.FillPath(&brush, &path);
    }
    Gdiplus::GraphicsPath card;
    roundedPath(card, layout.card, 20.0f * s);
    Gdiplus::SolidBrush background(dark ? color(RGB(0x1C, 0x1C, 0x1E), 242) : color(RGB(0xFF, 0xFF, 0xFF), 247));
    graphics.FillPath(&background, &card);
    if (content.phase == failure || content.phase == postProcessing) {
        Gdiplus::SolidBrush wash(color(tint, content.phase == failure ? 46 : 15));
        graphics.FillPath(&wash, &card);
    }
    Gdiplus::Pen stroke(color(tint, 115), 1.5f * s);
    graphics.DrawPath(&stroke, &card);

    // Phase glyph: a filled circle, pulsing while recording.
    if (content.phase == recording) {
        const float pulse = 0.5f + 0.5f * std::sin(static_cast<float>(elapsed) / 1000.0f * 3.14159f * 1.6f);
        Gdiplus::RectF ring = layout.glyph;
        ring.Inflate((3.0f + 3.0f * pulse) * s, (3.0f + 3.0f * pulse) * s);
        Gdiplus::SolidBrush halo(color(tint, static_cast<int>(40 + 40 * (1 - pulse))));
        graphics.FillEllipse(&halo, ring);
    }
    Gdiplus::LinearGradientBrush fill(layout.glyph, color(chrome::mix(tint, RGB(0xFF, 0xFF, 0xFF), 50)), color(tint),
                                      Gdiplus::LinearGradientModeVertical);
    graphics.FillEllipse(&fill, layout.glyph);
    Fonts fonts;
    const Gdiplus::Font icon(&fonts.icons(), 17.0f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::StringFormat centred;
    centred.SetAlignment(Gdiplus::StringAlignmentCenter);
    centred.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::SolidBrush white(color(RGB(0xFF, 0xFF, 0xFF)));
    const wchar_t glyph = phaseGlyph(content.phase);
    graphics.DrawString(&glyph, 1, &icon, layout.glyph, &centred, &white);

    Gdiplus::StringFormat top;
    top.SetAlignment(Gdiplus::StringAlignmentCenter);
    top.SetTrimming(Gdiplus::StringTrimmingEllipsisWord);
    const Gdiplus::Font headline(&fonts.strong(), 15.0f * s, fonts.strongStyle(), Gdiplus::UnitPixel);
    const Gdiplus::Font detail(&fonts.regular(), 12.5f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush primary(color(content.phase == failure ? tint : palette.text));
    Gdiplus::SolidBrush secondary(color(palette.secondary));
    graphics.DrawString(content.headline.c_str(), static_cast<INT>(content.headline.size()), &headline,
                        layout.headline, &top, &primary);
    if (!content.subheadline.empty()) {
        graphics.DrawString(content.subheadline.c_str(), static_cast<INT>(content.subheadline.size()), &detail,
                            layout.subheadline, &top, &secondary);
    }
    if (layout.showsMeter) {
        Gdiplus::GraphicsPath track;
        roundedPath(track, layout.meter, 2.0f * s);
        Gdiplus::SolidBrush trackBrush(color(palette.text, 38));
        graphics.FillPath(&trackBrush, &track);
        Gdiplus::RectF filled = layout.meter;
        filled.Width = std::max(filled.Height, layout.meter.Width * std::clamp(level, 0.0f, 1.0f));
        Gdiplus::GraphicsPath bar;
        roundedPath(bar, filled, 2.0f * s);
        Gdiplus::SolidBrush barBrush(color(tint));
        graphics.FillPath(&barBrush, &bar);
    }
    if (layout.showsClock) {
        const std::wstring text = clockText(elapsed);
        graphics.DrawString(text.c_str(), static_cast<INT>(text.size()), &detail, layout.clock, &top, &secondary);
    }
    if (layout.showsLive) {
        Gdiplus::GraphicsPath box;
        roundedPath(box, layout.liveBox, 10.0f * s);
        Gdiplus::SolidBrush field(color(palette.text, dark ? 20 : 12));
        graphics.FillPath(&field, &box);
        const Gdiplus::Font live(&fonts.regular(), 13.0f * s, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::StringFormat leading;
        Gdiplus::SolidBrush text(color(palette.text));
        graphics.DrawString(layout.liveShown.c_str(), static_cast<INT>(layout.liveShown.size()), &live, layout.live,
                            &leading, &text);
    }
}

UINT monitorDPI(HMONITOR monitor) {
    UINT x = 96, y = 96;
    return SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y)) && x ? x : 96;
}

void render() {
    if (!window) return;
    // The screen the user is working on: the foreground window's monitor.
    const HMONITOR monitor = MonitorFromWindow(GetForegroundWindow(), MONITOR_DEFAULTTOPRIMARY);
    MONITORINFO info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) return;
    const Layout layout = layoutFor(shown, monitorDPI(monitor));
    Surface surface(layout.width, layout.height);
    if (!surface.valid()) return;
    // Rises with each frame and falls back smoothly between them.
    meter = shown.phase == recording ? std::max(captureLevel(), meter * 0.82f) : 0.0f;
    draw(surface, layout, shown, GetTickCount64() - phaseStarted, meter);
    const RECT &work = info.rcWork;
    // The card's bottom edge sits 24 DIPs above the work area, as on the Mac.
    POINT position{work.left + (work.right - work.left - layout.width) / 2,
                   work.bottom - layout.height + static_cast<LONG>((margin - 24.0f) * layout.scale)};
    SIZE size{layout.width, layout.height};
    POINT origin{0, 0};
    BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(window, nullptr, &position, &size, surface.dc, &origin, 0, &blend, ULW_ALPHA);
}

void hide() {
    if (!window) return;
    KillTimer(window, tickTimer);
    KillTimer(window, hideTimer);
    ShowWindow(window, SW_HIDE);
    meter = 0;
}

LRESULT CALLBACK procedure(HWND handle, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
    case WM_NCHITTEST: return HTTRANSPARENT;
    case WM_TIMER:
        if (wparam == tickTimer) render();
        if (wparam == hideTimer) {
            shown = Content{};
            hide();
        }
        return 0;
    case WM_DESTROY:
        if (handle == window) window = nullptr;
        return 0;
    default: return DefWindowProcW(handle, message, wparam, lparam);
    }
}

bool ensureWindow() {
    if (window) return true;
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    if (!registered) {
        WNDCLASSW type{};
        type.lpfnWndProc = procedure;
        type.hInstance = instance;
        type.lpszClassName = className;
        type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        registered = RegisterClassW(&type) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
        if (!registered) return false;
    }
    // Never activated and click-through: insertion keeps the user's field.
    window = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
                             className, L"Just Speak to It", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, instance, nullptr);
    return window != nullptr;
}

} // namespace

bool stage(int phase, std::wstring headline, std::wstring subheadline, std::wstring live) {
    if (phase < hidden || phase >= phaseCount || headline.size() > 256 || subheadline.size() > 1024 ||
        live.size() > 2048) {
        return false;
    }
    std::lock_guard<std::mutex> lock(stagedLock);
    staged = Content{phase, std::move(headline), std::move(subheadline), std::move(live)};
    return true;
}

void apply() {
    Content next;
    {
        std::lock_guard<std::mutex> lock(stagedLock);
        next = staged;
    }
    if (next == shown && (next.phase == hidden || (window && IsWindowVisible(window)))) return;
    const bool newPhase = next.phase != shown.phase;
    shown = std::move(next);
    if (newPhase) phaseStarted = GetTickCount64();
    if (shown.phase == hidden) { hide(); return; }
    if (!ensureWindow()) return;
    KillTimer(window, hideTimer);
    if (terminal(shown.phase)) {
        KillTimer(window, tickTimer);
        SetTimer(window, hideTimer, shown.phase == success ? successMilliseconds : failureMilliseconds, nullptr);
    } else {
        SetTimer(window, tickTimer, tickMilliseconds, nullptr);
    }
    // Screen readers read the window's name; announce each new phase.
    const std::wstring name = shown.subheadline.empty() ? shown.headline : shown.headline + L". " + shown.subheadline;
    SetWindowTextW(window, name.c_str());
    render();
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOOWNERZORDER);
    if (newPhase) NotifyWinEvent(EVENT_SYSTEM_ALERT, window, OBJID_WINDOW, CHILDID_SELF);
}

void refresh() {
    if (window && IsWindowVisible(window)) render();
}

void destroy() {
    if (window) DestroyWindow(window);
    window = nullptr;
    shown = Content{};
    if (registered) UnregisterClassW(className, GetModuleHandleW(nullptr));
    registered = false;
}

bool saveSnapshot(const std::wstring &path, std::string &error) {
    const Layout layout = layoutFor(shown, 96);
    Surface surface(layout.width, layout.height);
    if (shown.phase == hidden || !surface.valid()) { error = "The recording HUD has nothing to show."; return false; }
    draw(surface, layout, shown, GetTickCount64() - phaseStarted, 0.55f);
    // Composite the premultiplied card over the window background.
    const COLORREF back = chrome::palette().window;
    std::vector<uint32_t> opaque(static_cast<size_t>(layout.width) * layout.height);
    for (size_t index = 0; index < opaque.size(); ++index) {
        const uint32_t pixel = surface.pixels[index];
        const uint32_t alpha = pixel >> 24;
        auto channel = [&](int shift, BYTE under) {
            return std::min<uint32_t>(255, ((pixel >> shift) & 0xFF) + under * (255 - alpha) / 255);
        };
        opaque[index] = 0xFF000000u | channel(16, GetRValue(back)) << 16 | channel(8, GetGValue(back)) << 8 |
                        channel(0, GetBValue(back));
    }
    BITMAPINFOHEADER info{};
    info.biSize = sizeof(info);
    info.biWidth = layout.width;
    info.biHeight = -layout.height;
    info.biPlanes = 1;
    info.biBitCount = 32;
    info.biCompression = BI_RGB;
    const DWORD bytes = static_cast<DWORD>(opaque.size() * sizeof(uint32_t));
    BITMAPFILEHEADER header{};
    header.bfType = 0x4D42;
    header.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    header.bfSize = header.bfOffBits + bytes;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) { error = systemError("Creating the HUD snapshot file"); return false; }
    DWORD written = 0;
    const bool ok = WriteFile(file, &header, sizeof(header), &written, nullptr) && written == sizeof(header) &&
                    WriteFile(file, &info, sizeof(info), &written, nullptr) && written == sizeof(info) &&
                    WriteFile(file, opaque.data(), bytes, &written, nullptr) && written == bytes;
    CloseHandle(file);
    if (!ok) error = systemError("Writing the HUD snapshot file");
    return ok;
}

bool selfTest(std::string &failure) {
    Content saved;
    {
        std::lock_guard<std::mutex> lock(stagedLock);
        saved = staged;
    }
    auto restore = [&] {
        {
            std::lock_guard<std::mutex> lock(stagedLock);
            staged = saved;
        }
        apply();
    };
    auto check = [&](bool condition, const char *problem) {
        if (!condition && failure.empty()) failure = std::string("Recording HUD: ") + problem;
        return condition;
    };
    const HWND foreground = GetForegroundWindow();
    stage(recording, L"Recording", L"Capturing audio", L"Could we move the catch-up to Friday?");
    apply();
    bool passed = check(window && IsWindowVisible(window), "the recording phase did not show the HUD.");
    if (passed) {
        const LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);
        const LONG_PTR required = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT;
        passed = check((style & required) == required, "the window can take focus, clicks or a taskbar button.") &&
                 check(GetForegroundWindow() == foreground, "showing the HUD changed the foreground window.");
        RECT bounds{};
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        GetWindowRect(window, &bounds);
        GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTOPRIMARY), &info);
        const LONG centre = (bounds.left + bounds.right) / 2, workCentre = (info.rcWork.left + info.rcWork.right) / 2;
        passed = passed && check(bounds.bottom <= info.rcWork.bottom && bounds.top >= info.rcWork.top &&
                                 std::abs(centre - workCentre) <= 1 && info.rcWork.bottom - bounds.bottom < 64,
                                 "the HUD is not at the bottom centre of the work area.");
    }
    stage(success, L"Completed", L"Transcript copied to the clipboard and saved to History.", L"");
    apply();
    passed = passed && check(IsWindowVisible(window), "the completed phase did not stay up.");
    stage(hidden, L"", L"", L"");
    apply();
    passed = passed && check(!IsWindowVisible(window), "hiding the HUD left it on screen.");
    restore();
    return passed;
}

} // namespace jsti::hud
