// Painting: the backdrop, owner-drawn controls, theme and font.
#include "WindowsWindowInternal.hpp"
#include "WindowsWindowHistoryPage.hpp"

namespace jsti_window {

// ------------------------------------------------------------- painting

void paintFrame(HWND window, HDC dc) {
    namespace chrome = jsti::chrome;
    const Frame &frame = layoutFrame();
    const JSTIVisualDensity visualDensity = currentVisualDensity();
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    RECT client{};
    GetClientRect(window, &client);
    RECT clip{};
    GetClipBox(dc, &clip);
    auto visible = [&](const RECT &rect) { RECT overlap{}; return IntersectRect(&overlap, &rect, &clip) != FALSE; };
    auto solid = [&](const RECT &rect, COLORREF color) {
        HBRUSH brush = CreateSolidBrush(color);
        FillRect(dc, &rect, brush);
        DeleteObject(brush);
    };
    solid(client, palette.window);
    if (visible(frame.sidebar)) {
        solid(frame.sidebar, palette.sidebar);
        solid(RECT{frame.sidebar.right - 1, 0, frame.sidebar.right, client.bottom}, palette.fieldBorder);
        chrome::brandIcon(dc, box(s(20), s(20), s(28), s(28)));
        chrome::text(dc, L"Just Speak to It", box(s(58), s(20), s(170), s(28)), chrome::Font::title, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, L"Speak", frame.speakHeading, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, L"Settings", frame.settingsHeading, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        // The search label draws over this from the backdrop, so the hint sits at its right.
        chrome::text(dc, L"Ctrl+K", frame.searchHint, chrome::Font::caption, dpi, palette.secondary,
                     DT_RIGHT | DT_SINGLELINE | DT_NOPREFIX);
    }
    if (visible(frame.header)) {
        const RECT title{frame.header.left + s(24), s(10), frame.header.right - s(300), s(36)};
        chrome::text(dc, pageInfo[state.page].title, title, chrome::Font::pageTitle, dpi, palette.text,
                     DT_LEFT | DT_BOTTOM | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, state.headerSubtitle, RECT{title.left, s(36), title.right, s(56)}, chrome::Font::caption, dpi,
                     palette.secondary, DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
    }
    solid(RECT{frame.status.left, frame.status.top, frame.status.right, frame.status.top + 1}, palette.fieldBorder);
    if (frame.hero.right > frame.hero.left && visible(frame.hero)) {
        const COLORREF tint = frame.gradient == chrome::Gradient::voice ? chrome::green : chrome::accentDeep;
        chrome::shadow(dc, frame.hero, s(28), tint, s(14));
        chrome::fillGradient(dc, frame.hero, s(28), frame.gradient);
        const int reserved = state.page == dashboardPage ? s(250) : state.page == historyPage ? s(170) : s(28);
        chrome::text(dc, frame.heroTitle, RECT{frame.hero.left + s(26), frame.hero.top + s(20), frame.hero.right - reserved,
                     frame.hero.top + s(58)}, chrome::Font::heroTitle, dpi, RGB(255, 255, 255),
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
        chrome::text(dc, frame.heroSubtitle, RECT{frame.hero.left + s(26), frame.hero.top + s(60), frame.hero.right - reserved,
                     frame.hero.top + s(100)}, chrome::Font::heroSubtitle, dpi, RGB(0xFF, 0xF4, 0xEE),
                     DT_LEFT | DT_WORDBREAK | DT_NOPREFIX | DT_END_ELLIPSIS);
        for (const auto &chip : frame.chips) {
            chrome::fillRound(dc, chip.rect, s(18), RGB(255, 255, 255), 44);
            std::wstring upper = chip.label;
            CharUpperBuffW(&upper[0], static_cast<DWORD>(upper.size()));
            chrome::text(dc, upper, RECT{chip.rect.left + s(14), chip.rect.top + s(9), chip.rect.right - s(8),
                         chip.rect.top + s(26)}, chrome::Font::smallBold, dpi, RGB(0xFF, 0xEE, 0xE6),
                         DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        }
    }
    for (const auto &card : frame.cards) {
        if (!visible(card.rect)) continue;
        chrome::shadow(dc, card.rect, s(24), chrome::accentDeep, s(10));
        chrome::fillRound(dc, card.rect, s(24), palette.card);
        chrome::strokeRound(dc, card.rect, s(24), chrome::accentDeep, chrome::dark() ? 70 : 40, 1.0f);
        const RECT tile = box(card.rect.left + densitySpace(window, 20, visualDensity.card_padding),
                              card.rect.top + densitySpace(window, 18, visualDensity.card_padding), s(36), s(36));
        chrome::fillRound(dc, tile, s(12), chrome::accent, chrome::dark() ? 60 : 38);
        chrome::glyph(dc, card.glyph, tile, chrome::dark() ? RGB(0xFF, 0x8A, 0x5C) : chrome::accentDeep, dpi);
        chrome::text(dc, card.title, RECT{tile.right + densitySpace(window, 12, visualDensity.inline_spacing), tile.top,
                     card.rect.right - densitySpace(window, 20, visualDensity.card_padding), tile.bottom},
                     chrome::Font::title, dpi, palette.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    }
    for (const auto &stat : frame.stats) {
        chrome::fillRound(dc, stat.rect, s(16), chrome::accent, chrome::dark() ? 34 : 22);
        chrome::text(dc, stat.label, RECT{stat.rect.left + s(14), stat.rect.top + s(8), stat.rect.right - s(8),
                     stat.rect.top + s(28)}, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
    }
    for (const auto &tile : frame.tiles) {
        chrome::fillRound(dc, tile.rect, s(16), palette.field);
        chrome::strokeRound(dc, tile.rect, s(16), chrome::green, 110, 1.0f);
        chrome::glyph(dc, tile.glyph, box(tile.rect.left + s(8), tile.rect.top + s(6), s(22), s(22)), chrome::accentDeep, dpi);
        chrome::text(dc, tile.title, RECT{tile.rect.left + s(34), tile.rect.top + s(6), tile.rect.right - s(8),
                     tile.rect.top + s(28)}, chrome::Font::bodySemibold, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    }
    for (const auto &field : frame.fields) {
        chrome::fillRound(dc, field, s(10), palette.field);
        chrome::strokeRound(dc, field, s(10), palette.fieldBorder, 255, 1.0f);
    }
    for (const auto &paragraph : frame.paragraphs) {
        chrome::text(dc, paragraph.text, paragraph.rect, paragraph.font, dpi,
                     paragraph.secondary ? palette.secondary : palette.text, DT_LEFT | DT_WORDBREAK | DT_NOPREFIX);
    }
    if (frame.icon.right > frame.icon.left) chrome::brandIcon(dc, frame.icon);
}
namespace {
// The painted window, rendered once per change and copied from: WM_PAINT,
// WM_PRINTCLIENT and every owner-drawn control's background come from it, so
// GDI+ only ever draws on a memory DC with no viewport offset.
struct Backdrop {
    HDC dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    int width = 0, height = 0;
    bool dirty = true;
    void release() {
        if (dc && previous) SelectObject(dc, previous);
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        *this = Backdrop{};
    }
};
Backdrop backdrop;
} // namespace

// Controls draw their own backgrounds from the backdrop, so a new backdrop
// repaints them too.
void invalidateBackdrop(HWND window) {
    backdrop.dirty = true;
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
}

HDC backdropDC(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    const int width = std::max<int>(client.right, 1), height = std::max<int>(client.bottom, 1);
    if (!backdrop.dc || backdrop.width != width || backdrop.height != height) {
        backdrop.release();
        HDC screen = GetDC(window);
        backdrop.dc = CreateCompatibleDC(screen);
        backdrop.bitmap = CreateCompatibleBitmap(screen, width, height);
        ReleaseDC(window, screen);
        if (!backdrop.dc || !backdrop.bitmap) { backdrop.release(); return nullptr; }
        backdrop.previous = SelectObject(backdrop.dc, backdrop.bitmap);
        backdrop.width = width;
        backdrop.height = height;
        backdrop.dirty = true;
    }
    if (backdrop.dirty) {
        paintFrame(window, backdrop.dc);
        backdrop.dirty = false;
    }
    return backdrop.dc;
}

// The client belongs at the DC's device origin. A WM_PRINT caller may have
// moved the viewport so child windows land at their window-relative offsets
// (the snapshot does), and Windows passes that DC on unchanged.
void printBackdrop(HWND window, HDC target) {
    HDC source = backdropDC(window);
    POINT origin{};
    GetViewportOrgEx(target, &origin);
    if (source) BitBlt(target, -origin.x, -origin.y, backdrop.width, backdrop.height, source, 0, 0, SRCCOPY);
}

void releaseBackdrop() { backdrop.release(); }

// Copies what lies behind `control` to (0, 0) of `target`.
void copyBackdrop(HWND window, HDC target, HWND control, int width, int height) {
    const auto &placed = placedControls();
    const auto found = placed.find(GetDlgCtrlID(control));
    RECT rect{};
    if (found != placed.end()) rect = found->second;
    else {
        GetWindowRect(control, &rect);
        MapWindowPoints(nullptr, window, reinterpret_cast<POINT *>(&rect), 2);
    }
    HDC source = backdropDC(window);
    if (source) BitBlt(target, 0, 0, width, height, source, rect.left, rect.top, SRCCOPY);
}

// A memory bitmap the size of an owner-drawn item, copied to it when done.
struct Canvas {
    HDC target, dc = nullptr;
    HBITMAP bitmap = nullptr;
    HGDIOBJ previous = nullptr;
    RECT item;
    Canvas(HDC target, const RECT &item) : target(target), item(item) {
        dc = CreateCompatibleDC(target);
        bitmap = CreateCompatibleBitmap(target, std::max<int>(widthOf(item), 1), std::max<int>(heightOf(item), 1));
        if (dc && bitmap) previous = SelectObject(dc, bitmap);
    }
    ~Canvas() {
        if (dc && bitmap) BitBlt(target, item.left, item.top, widthOf(item), heightOf(item), dc, 0, 0, SRCCOPY);
        if (previous) SelectObject(dc, previous);
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
    }
    RECT bounds() const { return RECT{0, 0, widthOf(item), heightOf(item)}; }
    bool ready() const { return dc && bitmap; }
};

// ------------------------------------------------------ owner-drawn controls

std::wstring controlText(HWND control) {
    const int length = std::max(GetWindowTextLengthW(control), 0);
    std::wstring value(static_cast<size_t>(length) + 1, 0);
    GetWindowTextW(control, &value[0], length + 1);
    value.resize(static_cast<size_t>(length));
    return value;
}

COLORREF navTint(int page) {
    switch (page) {
    case dashboardPage: return jsti::chrome::lagoon;
    case historyPage: return jsti::chrome::accentDeep;
    case voicePage: return jsti::chrome::green;
    default: return RGB(0xF0, 0x8A, 0x2C);
    }
}

void drawControl(HWND window, const DRAWITEMSTRUCT &item) {
    namespace chrome = jsti::chrome;
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    Canvas canvas(item.hDC, item.rcItem);
    if (!canvas.ready()) return;
    HDC dc = canvas.dc;
    RECT rect = canvas.bounds();
    copyBackdrop(window, dc, item.hwndItem, widthOf(rect), heightOf(rect));
    const int identifier = static_cast<int>(item.CtlID);
    const std::wstring label = controlText(item.hwndItem);
    const bool disabled = (item.itemState & ODS_DISABLED) != 0;
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const bool focused = (item.itemState & ODS_FOCUS) != 0 && (item.itemState & ODS_NOFOCUSRECT) == 0;
    const UINT centred = DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS;
    const Role role = roleOf(window, identifier);
    const int recording = state.displayedRecording;
    switch (role) {
    case Role::nav: {
        const int page = identifier - navBaseID;
        const bool selected = page == state.page;
        if (selected) chrome::fillRound(dc, rect, s(10), chrome::accent, chrome::dark() ? 58 : 40);
        else if (pressed) chrome::fillRound(dc, rect, s(10), palette.text, 20);
        chrome::glyph(dc, pageInfo[page].glyph, box(rect.left + s(8), rect.top, s(28), heightOf(rect)), navTint(page), dpi);
        const auto &hint = state.sidebar.hints[page];
        const bool showHint = state.sidebar.showHints && !hint.empty() &&
            !jsti_hotkey_reserves_sidebar_digit(state.sidebar.digits[page]);
        chrome::text(dc, pageInfo[page].title,
                     RECT{rect.left + s(42), rect.top, rect.right - s(showHint ? 62 : 8), rect.bottom},
                     selected ? chrome::Font::bodySemibold : chrome::Font::body, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
        if (showHint) chrome::text(dc, hint, RECT{rect.right - s(60), rect.top, rect.right - s(8), rect.bottom},
                                  chrome::Font::caption, dpi, palette.secondary, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
        break;
    }
    case Role::record: {
        const bool live = recording == 1;
        if (disabled) chrome::fillRound(dc, rect, heightOf(rect) / 2, palette.secondary, 90);
        else chrome::fillGradient(dc, rect, heightOf(rect) / 2, live ? chrome::Gradient::recording : chrome::Gradient::record);
        if (pressed) chrome::fillRound(dc, rect, heightOf(rect) / 2, RGB(0, 0, 0), 30);
        const bool large = heightOf(rect) > s(44);
        const std::wstring shown = recording == 1 ? (large ? L"Stop Recording" : L"Stop")
            : recording == 2 ? (large ? L"Cancel operation" : L"Cancel") : (large ? L"Start Recording" : L"Record");
        HGDIOBJ previous = SelectObject(dc, chrome::font(chrome::Font::bodySemibold, dpi));
        SIZE extent{};
        GetTextExtentPoint32W(dc, shown.c_str(), static_cast<int>(shown.size()), &extent);
        SelectObject(dc, previous);
        const int icon = s(20), spacing = s(8);
        const int start = rect.left + (widthOf(rect) - icon - spacing - extent.cx) / 2;
        chrome::glyph(dc, recording == 1 ? 0xE71A : 0xE720, box(start, rect.top, icon, heightOf(rect)), RGB(255, 255, 255), dpi);
        chrome::text(dc, shown, RECT{start + icon + spacing, rect.top, rect.right, rect.bottom}, chrome::Font::bodySemibold,
                     dpi, RGB(255, 255, 255), DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        break;
    }
    case Role::primary:
    case Role::button:
    case Role::heroButton: {
        const int radius = s(9);
        COLORREF ink = palette.text;
        if (role == Role::primary) {
            chrome::fillRound(dc, rect, radius, disabled ? chrome::mix(palette.window, chrome::accentDeep, 90) : chrome::accentDeep);
            ink = RGB(255, 255, 255);
        } else if (role == Role::heroButton) {
            chrome::fillRound(dc, rect, radius, RGB(255, 255, 255), disabled ? 30 : 56);
            ink = RGB(255, 255, 255);
        } else {
            chrome::fillRound(dc, rect, radius, palette.field);
            chrome::strokeRound(dc, rect, radius, palette.fieldBorder, 255, 1.0f);
            if (disabled) ink = chrome::mix(palette.field, palette.secondary, 150);
        }
        if (pressed) chrome::fillRound(dc, rect, radius, RGB(0, 0, 0), 26);
        chrome::text(dc, label, RECT{rect.left + s(6), rect.top, rect.right - s(6), rect.bottom}, chrome::Font::bodySemibold,
                     dpi, ink, centred);
        break;
    }
    case Role::toggle: {
        // updateSettingsButtons keeps each switch's state in its user data.
        const bool on = GetWindowLongPtrW(item.hwndItem, GWLP_USERDATA) != 0;
        const RECT track = box(rect.right - s(46), rect.top + (heightOf(rect) - s(24)) / 2, s(44), s(24));
        chrome::fillRound(dc, track, s(12), on ? chrome::accentDeep : palette.fieldBorder);
        const RECT knob = box(on ? track.right - s(21) : track.left + s(3), track.top + s(3), s(18), s(18));
        chrome::fillRound(dc, knob, s(9), RGB(255, 255, 255));
        chrome::text(dc, label, RECT{rect.left, rect.top, track.left - s(12), rect.bottom}, chrome::Font::body, dpi,
                     disabled ? palette.secondary : palette.text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
        break;
    }
    case Role::link: break;
    case Role::chipValue:
        chrome::text(dc, label, rect, chrome::Font::chipValue, dpi, RGB(255, 255, 255),
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::statValue:
        chrome::text(dc, label, rect, chrome::Font::chipValue, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::tileValue:
        chrome::text(dc, label, rect, chrome::Font::caption, dpi, palette.secondary,
                     DT_LEFT | DT_TOP | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::value:
        chrome::text(dc, label, rect, chrome::Font::title, dpi, palette.text,
                     DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::caption: {
        // The shortcut hint repeats the card's "Transcript" title; show only the shortcut.
        std::wstring shown = label;
        const std::wstring prefix = L"Transcript \u2014 ";
        if (identifier == transcriptLabelID && shown.compare(0, prefix.size(), prefix) == 0) shown.erase(0, prefix.size());
        chrome::text(dc, shown, rect, chrome::Font::caption, dpi, palette.secondary,
                     (identifier == transcriptLabelID ? DT_RIGHT | DT_SINGLELINE : DT_LEFT | DT_WORDBREAK) |
                     DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    }
    case Role::status:
        chrome::text(dc, label, rect, chrome::Font::body, dpi, palette.text, DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX);
        return;
    case Role::label:
    case Role::detail:
        chrome::text(dc, label, rect, chrome::Font::bodySemibold, dpi, palette.text, DT_LEFT | DT_WORDBREAK);
        return;
    }
    if (focused) {
        RECT ring = rect;
        chrome::strokeRound(dc, ring, role == Role::record ? heightOf(rect) / 2 : s(10), chrome::accent, 220, 2.0f);
    }
}

// One History card: badges, the preview and the models line.
void drawHistoryItem(HWND window, const DRAWITEMSTRUCT &item) {
    namespace chrome = jsti::chrome;
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    Canvas canvas(item.hDC, item.rcItem);
    if (!canvas.ready()) return;
    HDC dc = canvas.dc;
    RECT area = canvas.bounds();
    HBRUSH background = CreateSolidBrush(palette.window);
    FillRect(dc, &area, background);
    DeleteObject(background);
    if (item.itemID == static_cast<UINT>(-1) || item.itemID >= historyView().displayedHistory.size()) return;
    // Drawing the last row of a scrolled list means it scrolled into view: ask
    // the host for the next page of matches once per list. The host ignores it
    // when none remain; a list that fits without scrolling was never cut short.
    if (item.itemID + 1 == historyView().displayedHistory.size() && !historyView().historyMoreRequested &&
        SendMessageW(item.hwndItem, LB_GETTOPINDEX, 0, 0) > 0) {
        historyView().historyMoreRequested = true;
        emit(window, JSTI_EVENT_HISTORY_LOAD_MORE);
    }
    const HistoryRow &row = historyView().displayedHistory[item.itemID];
    RECT card{area.left + s(2), area.top + s(5), area.right - s(4), area.bottom - s(5)};
    const bool selected = (item.itemState & ODS_SELECTED) != 0;
    chrome::fillRound(dc, card, s(20), palette.card);
    const COLORREF edge = row.tone == 1 ? chrome::orange : chrome::accentDeep;
    chrome::strokeRound(dc, card, s(20), edge, selected ? 230 : (row.tone == 1 ? 120 : 50), selected ? 2.0f : 1.0f);
    int x = card.left + s(16);
    const int top = card.top + s(12);
    auto badge = [&](const std::wstring &title, const std::wstring &value, COLORREF tint) {
        if (value.empty()) return;
        HGDIOBJ previous = SelectObject(dc, chrome::font(chrome::Font::caption, dpi));
        SIZE extent{};
        GetTextExtentPoint32W(dc, value.c_str(), static_cast<int>(value.size()), &extent);
        SelectObject(dc, previous);
        const int width = std::min<int>(std::max<int>(extent.cx, s(52)) + s(20), card.right - s(16) - x);
        if (width < s(48)) return;
        const RECT shape = box(x, top, width, s(40));
        chrome::fillRound(dc, shape, s(10), tint, chrome::dark() ? 52 : 32);
        std::wstring upper = title;
        CharUpperBuffW(&upper[0], static_cast<DWORD>(upper.size()));
        chrome::text(dc, upper, RECT{shape.left + s(10), shape.top + s(4), shape.right - s(6), shape.top + s(18)},
                     chrome::Font::smallBold, dpi, tint, DT_LEFT | DT_SINGLELINE | DT_NOPREFIX);
        chrome::text(dc, value, RECT{shape.left + s(10), shape.top + s(18), shape.right - s(6), shape.bottom - s(3)},
                     chrome::Font::caption, dpi, tint, DT_LEFT | DT_SINGLELINE | DT_NOPREFIX | DT_END_ELLIPSIS);
        x = shape.right + s(8);
    };
    badge(L"Created", row.created, chrome::blue);
    badge(L"Audio", row.audio, chrome::blue);
    badge(L"Cost", row.cost, chrome::green);
    badge(L"Context", row.context, chrome::lagoon);
    if (row.tone == 1) badge(L"Error", L"Needs attention", chrome::orange);
    else if (row.tone == 2) badge(L"Status", L"Not transcribed", chrome::orange);
    const RECT preview{card.left + s(16), top + s(48), card.right - s(16), card.bottom - s(28)};
    chrome::text(dc, row.preview.empty() ? row.detail : row.preview, preview, chrome::Font::body, dpi, palette.text,
                 DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS | DT_NOPREFIX | DT_EDITCONTROL);
    chrome::glyph(dc, 0xE713, box(card.left + s(14), card.bottom - s(26), s(18), s(18)), palette.secondary, dpi);
    chrome::text(dc, row.models.empty() ? row.title : row.models, RECT{card.left + s(36), card.bottom - s(28),
                 card.right - s(16), card.bottom - s(8)}, chrome::Font::caption, dpi, palette.secondary,
                 DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
}

bool highContrast() {
    HIGHCONTRASTW contrast{};
    contrast.cbSize = sizeof(contrast);
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) &&
        (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0;
}

// One settings search result: its title over a dimmer detail. High contrast
// uses the system's window and highlight colours.
void drawSettingsResult(HWND window, const DRAWITEMSTRUCT &item) {
    namespace chrome = jsti::chrome;
    const auto &palette = chrome::palette();
    const UINT dpi = GetDpiForWindow(window);
    auto s = [&](int value) { return scale(window, value); };
    Canvas canvas(item.hDC, item.rcItem);
    if (!canvas.ready()) return;
    HDC dc = canvas.dc;
    RECT area = canvas.bounds();
    const bool contrast = highContrast();
    const bool selected = (item.itemState & ODS_SELECTED) != 0;
    HBRUSH background = CreateSolidBrush(contrast ? GetSysColor(selected ? COLOR_HIGHLIGHT : COLOR_WINDOW)
                                                  : palette.sidebar);
    FillRect(dc, &area, background);
    DeleteObject(background);
    const SettingsSearchRow *shown = item.itemID == static_cast<UINT>(-1) ? nullptr : settingsSearchRow(item.itemID);
    if (!shown) return;
    const SettingsSearchRow &row = *shown;
    if (selected && !contrast)
        chrome::fillRound(dc, RECT{area.left, area.top + s(2), area.right, area.bottom - s(2)}, s(10), chrome::accent,
                          chrome::dark() ? 58 : 40);
    const COLORREF ink = contrast ? GetSysColor(selected ? COLOR_HIGHLIGHTTEXT : COLOR_WINDOWTEXT) : palette.text;
    const COLORREF dim = contrast ? ink : palette.secondary;
    const int width = widthOf(area) - s(22);
    const int titleHeight = chrome::measure(dc, L"Ag", width, chrome::Font::bodySemibold, dpi);
    const int detailHeight = chrome::measure(dc, L"Ag", width, chrome::Font::caption, dpi);
    const int top = area.top + std::max(0, (heightOf(area) - titleHeight - detailHeight - s(2)) / 2);
    const RECT title{area.left + s(12), top, area.right - s(10), top + titleHeight};
    const RECT detail{title.left, title.bottom + s(2), title.right, title.bottom + s(2) + detailHeight};
    const UINT line = DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX;
    chrome::text(dc, row.title, title, chrome::Font::bodySemibold, dpi, ink, line);
    chrome::text(dc, row.detail, detail, chrome::Font::caption, dpi, dim, line);
    if ((item.itemState & ODS_FOCUS) != 0 && (item.itemState & ODS_NOFOCUSRECT) == 0) {
        RECT ring = area;
        InflateRect(&ring, -s(1), -s(1));
        if (contrast) DrawFocusRect(dc, &ring);
        else chrome::strokeRound(dc, ring, s(10), chrome::accent, 220, 2.0f);
    }
}

// ------------------------------------------------------------ appearance

HBRUSH brushFor(COLORREF color) {
    static std::unordered_map<COLORREF, HBRUSH> brushes;
    const auto found = brushes.find(color);
    if (found != brushes.end()) return found->second;
    HBRUSH created = CreateSolidBrush(color);
    brushes[color] = created;
    return created;
}

// Dark or light native controls, title bar and repaint, after the choice or
// Windows' own setting changes.
void applyTheme(HWND window) {
    // The backup check boxes draw unthemed in dark mode so WM_CTLCOLORSTATIC's
    // light text applies; themed check box labels stay black on the dark card.
    jsti::chrome::themeTitleBar(window);
    for (HWND control : state.controls) jsti::chrome::themeControl(control);
    // Open dialogs follow an in-app Appearance change too.
    EnumThreadWindows(GetCurrentThreadId(), [](HWND other, LPARAM owner) -> BOOL {
        if (GetWindow(other, GW_OWNER) == reinterpret_cast<HWND>(owner)) {
            jsti::chrome::themeWindow(other);
            RedrawWindow(other, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_FRAME);
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(window));
    backdrop.dirty = true;
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_FRAME);
    jsti::hud::refresh();
    jsti_history_filters_refresh_theme();
}

void refreshFont(HWND window) {
    const UINT dpi = GetDpiForWindow(window);
    for (HWND control : state.controls) {
        const HFONT chosen = GetDlgCtrlID(control) == transcriptID
            ? jsti::chrome::font(jsti::chrome::Font::mono, dpi) : jsti::chrome::font(jsti::chrome::Font::body, dpi);
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(chosen), TRUE);
    }
    SendDlgItemMessageW(window, historyID, LB_SETITEMHEIGHT, 0, scale(window, 132));
    SendDlgItemMessageW(window, settingsResultsID, LB_SETITEMHEIGHT, 0, settingsResultHeight(window));
}
} // namespace jsti_window
