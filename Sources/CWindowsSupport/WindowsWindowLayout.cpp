// Page layout: which controls each page shows and where they are placed.
#include "WindowsWindowInternal.hpp"

namespace jsti_window {

// The Mac's 232-point sidebar, widened when a page title (semibold, as when
// selected) plus the Ctrl+digit hint's space would clip in the current font
// and DPI. The hint's space is always reserved so the width does not change
// when hints are turned on or off.
int measuredSidebarWidth(HWND window) {
    const UINT dpi = GetDpiForWindow(window);
    int widest = 0;
    if (HDC dc = GetDC(window)) {
        HGDIOBJ previous = SelectObject(dc, jsti::chrome::font(jsti::chrome::Font::bodySemibold, dpi));
        for (const auto &page : pageInfo) {
            SIZE extent{};
            if (GetTextExtentPoint32W(dc, page.title, static_cast<int>(wcslen(page.title)), &extent)) {
                widest = std::max<int>(widest, extent.cx);
            }
        }
        SelectObject(dc, previous);
        ReleaseDC(window, dc);
    }
    // Row inset 10 each side, glyph column 42, hint column 62, and 4 for ClearType overhang.
    return std::max(scale(window, 232), widest + scale(window, 10 + 42 + 62 + 4 + 10));
}

// The smallest window every page fits in without scrolling, as the Mac's
// 960 × 640 main window minimum, plus the sidebar and status line.
int minimumWindowWidth(HWND window) { return scale(window, 980) + measuredSidebarWidth(window) - scale(window, 232); }
int minimumWindowHeight(HWND window) { return scale(window, 760); }

// ------------------------------------------------------------------ pages

// Which pages show a control. Controls outside this list belong to Transcription.
unsigned pagesOf(int identifier) {
    constexpr unsigned all = (1u << pageCount) - 1;
    auto page = [](int value) { return 1u << value; };
    if (identifier >= navBaseID && identifier < navBaseID + pageCount) return all;
    if (identifier >= aboutLinkBaseID && identifier < aboutLinkBaseID + 8) return page(aboutPage);
    switch (identifier) {
    case statusID: case recordID: case importID: return all;
    case settingsSearchLabelID: case settingsSearchID: case settingsResultsID: case settingsNoMatchID: return all;
    case transcriptID: case transcriptNameID: case copyID: return page(dashboardPage) | page(historyPage);
    case transcriptLabelID: case chipSessionsID: case chipTimeID: case chipSpendID:
    case insightSessionsID: case insightTimeID: case insightAverageID: case insightSpendID:
    case setupMicrophoneID: case setupModelID: case setupShortcutID: case setupOutputID:
        return page(dashboardPage);
    case searchLabelID: case searchID: case clearSearchID: case historyFiltersID:
    case issueReportID: case historyDeleteID: case historyClearID: case 93: case historyID: case historyDetailID:
    case variantLabelID: case variantID: case retryID: case exportID: case openAudioID: case playbackLabelID:
    case playbackTimeID: case playPauseID: case historySessionsID: case historyErrorsID: case historyAverageID:
    case historySpendID: case historyCorrectionsID:
        return page(historyPage);
    case readAloudID: case stopPlaybackID: return page(historyPage) | page(voicePage);
    case voiceSettingsID: case voiceSourcesID: case voiceCredentialID: return page(voicePage);
    case configurationID:
        return page(generalPage) | page(transcriptionPage) | page(postProcessingPage) | page(keyboardPage) |
            page(correctionsPage);
    case 94: case microphoneID: case textOutputID: case appearanceLabelID: case appearanceID: case automationID:
    case loginItemID: case recordingsFolderLabelID: case recordingsFolderID: case audioCleanupID:
    case backupAudioID: case backupProfilesID: case backupExportID: case backupInspectID:
    case backupRestoreID:
    case automationSettingsID:
        return page(generalPage);
    case processingID: return page(postProcessingPage);
    case profilesID: return page(profilesPage);
    case correctionsID: return page(correctionsPage);
    case pronunciationID: return page(pronunciationPage);
    case comparisonID: return page(transcriptionPage);
    case shortcutValueID: case shortcutID: case actionShortcutsID: return page(keyboardPage);
    case cloudSyncID: return page(cloudSyncPage);
    case aboutDetailsID: case setupGuideID: case permissionsID: case troubleshootingID: return page(aboutPage);
    default: return page(transcriptionPage);
    }
}

bool onPage(int identifier, int page) { return (pagesOf(identifier) & (1u << page)) != 0; }

// Feature visibility (Mode, Source, Refresh or Local models) is remembered
// here and combined with the current page, so a hidden page never shows them.
void setShown(HWND window, int identifier, bool shown) {
    state.wanted[identifier] = shown;
    ShowWindow(GetDlgItem(window, identifier), shown && onPage(identifier, state.page) ? SW_SHOWNA : SW_HIDE);
}

void applyVisibility(HWND window) {
    for (HWND control : state.controls) {
        const int identifier = GetDlgCtrlID(control);
        const auto found = state.wanted.find(identifier);
        const bool shown = (found == state.wanted.end() || found->second) && onPage(identifier, state.page);
        if ((IsWindowVisible(control) != FALSE) != shown) ShowWindow(control, shown ? SW_SHOWNA : SW_HIDE);
    }
}

Role roleOf(HWND window, int identifier) {
    if (identifier >= navBaseID && identifier < navBaseID + pageCount) return Role::nav;
    switch (identifier) {
    case recordID: return Role::record;
    case copyID: case saveID: return Role::primary;
    case importID: return state.page == historyPage ? Role::heroButton : Role::button;
    case automationID: case loginItemID: return Role::toggle;
    case statusID: case aboutDetailsID: return Role::status;
    case historyDetailID: case modelStatusID: case transcriptLabelID: case settingsSearchLabelID:
    case settingsNoMatchID: return Role::caption;
    case playbackTimeID: case shortcutValueID: return Role::value;
    case chipSessionsID: case chipTimeID: case chipSpendID: case historySessionsID: case historyErrorsID:
    case historyAverageID: case historySpendID: return Role::chipValue;
    case insightSessionsID: case insightTimeID: case insightAverageID: case insightSpendID: return Role::statValue;
    case setupMicrophoneID: case setupModelID: case setupShortcutID: case setupOutputID: return Role::tileValue;
    default: break;
    }
    wchar_t kind[16] = {};
    GetClassNameW(GetDlgItem(window, identifier), kind, 16);
    return _wcsicmp(kind, L"STATIC") == 0 ? Role::label : Role::button;
}
Frame frame;

JSTIVisualDensity visualDensity{};

int densitySpace(HWND window, int normal, int compact) {
    return scale(window, visualDensity.compact ? compact : normal);
}

int cardHeaderHeight(HWND window) {
    return densitySpace(window, 66, 36 + 2 * visualDensity.card_padding);
}

RECT box(int x, int y, int width, int height) { return RECT{x, y, x + width, y + height}; }
int widthOf(const RECT &rect) { return rect.right - rect.left; }
int heightOf(const RECT &rect) { return rect.bottom - rect.top; }

// Every control's client-area rectangle, as placed, for its painted backdrop.
std::unordered_map<int, RECT> placed;

void place(HWND window, int identifier, const RECT &rect) {
    placed[identifier] = rect;
    MoveWindow(GetDlgItem(window, identifier), rect.left, rect.top, widthOf(rect), heightOf(rect), FALSE);
}

// A text field: the control sits inside a painted rounded field.
void placeField(HWND window, int identifier, RECT rect, bool multiline = false) {
    frame.fields.push_back(rect);
    const int horizontal = scale(window, 10);
    const int vertical = multiline ? scale(window, 8) : std::max(0, (heightOf(rect) - scale(window, 20)) / 2);
    InflateRect(&rect, -horizontal, -vertical);
    place(window, identifier, rect);
}

std::wstring heroTitle(int page) {
    switch (page) {
    case dashboardPage: return L"Speak Dashboard";
    case historyPage: return L"Session History";
    default: return pageInfo[page].title;
    }
}

// A hero across the top of the content. Returns its bottom.
int layoutHero(HWND window, const RECT &content, int height, jsti::chrome::Gradient gradient) {
    frame.hero = box(content.left, content.top, widthOf(content), height);
    frame.gradient = gradient;
    frame.heroTitle = heroTitle(state.page);
    frame.heroSubtitle = pageInfo[state.page].subtitle;
    return frame.hero.bottom;
}

// Chips along the hero's bottom edge; each value is the static `ids[index]`.
void layoutChips(HWND window, const std::vector<std::pair<int, std::wstring>> &chips) {
    const int inset = scale(window, 26), spacing = scale(window, 12), height = scale(window, 62);
    const int available = widthOf(frame.hero) - 2 * inset - spacing * static_cast<int>(chips.size() - 1);
    const int width = std::min(scale(window, 190), available / static_cast<int>(chips.size()));
    const int top = frame.hero.bottom - inset - height;
    for (size_t index = 0; index < chips.size(); ++index) {
        const RECT chip = box(frame.hero.left + inset + static_cast<int>(index) * (width + spacing), top, width, height);
        frame.chips.push_back({chip, chips[index].second});
        place(window, chips[index].first, box(chip.left + scale(window, 14), chip.top + scale(window, 26),
                                              width - scale(window, 28), scale(window, 28)));
    }
}

Card &addCard(RECT rect, wchar_t glyph, const std::wstring &title) {
    frame.cards.push_back({rect, glyph, title});
    return frame.cards.back();
}

// The card's content area below its title row.
RECT cardBody(HWND window, const RECT &card) {
    const int inset = densitySpace(window, 22, visualDensity.card_padding);
    return RECT{card.left + inset, card.top + cardHeaderHeight(window), card.right - inset,
                card.bottom - densitySpace(window, 20, visualDensity.card_padding)};
}

// Sets a control's text only when it changes, so layout never repaints needlessly.
void setLabel(HWND window, int identifier, const wchar_t *text) {
    wchar_t shown[64] = {};
    GetDlgItemTextW(window, identifier, shown, 64);
    if (wcscmp(shown, text) != 0) SetDlgItemTextW(window, identifier, text);
}

void layoutDashboard(HWND window, const RECT &content) {
    const int gap = densitySpace(window, 18, visualDensity.section_spacing);
    const int heroBottom = layoutHero(window, content, scale(window, 200), jsti::chrome::Gradient::brand);
    place(window, recordID, box(frame.hero.right - scale(window, 26) - scale(window, 196), frame.hero.top + scale(window, 26),
                                scale(window, 196), scale(window, 50)));
    layoutChips(window, {{chipSessionsID, L"Sessions"}, {chipTimeID, L"Recording Time"}, {chipSpendID, L"Spend"}});
    const int rowHeight = scale(window, 190);
    const RECT transcript{content.left, heroBottom + gap, content.right, content.bottom - rowHeight - gap};
    addCard(transcript, 0xE70F, L"Transcript");
    place(window, transcriptLabelID, RECT{transcript.left + widthOf(transcript) / 3, transcript.top + scale(window, 26),
                                          transcript.right - scale(window, 22), transcript.top + scale(window, 46)});
    const RECT body = cardBody(window, transcript);
    const int buttonHeight = scale(window, 34);
    placeField(window, transcriptID, RECT{body.left, body.top, body.right, body.bottom - buttonHeight - scale(window, 12)}, true);
    place(window, copyID, box(body.right - scale(window, 156), body.bottom - buttonHeight, scale(window, 156), buttonHeight));
    setLabel(window, copyID, L"&Copy transcript");
    const int half = (widthOf(content) - gap) / 2;
    const RECT insights = box(content.left, content.bottom - rowHeight, half, rowHeight);
    const RECT setup = box(content.left + half + gap, content.bottom - rowHeight, widthOf(content) - half - gap, rowHeight);
    addCard(insights, 0xE9D2, L"Insights");
    addCard(setup, 0xE713, L"Setup");
    auto grid = [&](const RECT &card, int index) {
        const RECT inner = cardBody(window, card);
        const int spacing = scale(window, 10);
        const int width = (widthOf(inner) - spacing) / 2, height = (heightOf(inner) - spacing) / 2;
        return box(inner.left + (index % 2) * (width + spacing), inner.top + (index / 2) * (height + spacing), width, height);
    };
    const std::pair<int, const wchar_t *> stats[] = {
        {insightSessionsID, L"Sessions"}, {insightTimeID, L"Recording Time"},
        {insightAverageID, L"Average Length"}, {insightSpendID, L"Spend"}};
    for (int index = 0; index < 4; ++index) {
        const RECT tile = grid(insights, index);
        frame.stats.push_back({tile, stats[index].second});
        place(window, stats[index].first, RECT{tile.left + scale(window, 14), tile.bottom - scale(window, 30),
                                               tile.right - scale(window, 10), tile.bottom - scale(window, 6)});
    }
    const std::tuple<int, wchar_t, const wchar_t *> tiles[] = {
        {setupMicrophoneID, 0xE720, L"Microphone"}, {setupModelID, 0xE70F, L"Model"},
        {setupShortcutID, 0xE765, L"Shortcut"}, {setupOutputID, 0xE8C8, L"Text output"}};
    for (int index = 0; index < 4; ++index) {
        const RECT tile = grid(setup, index);
        frame.tiles.push_back({tile, std::get<1>(tiles[index]), std::get<2>(tiles[index])});
        place(window, std::get<0>(tiles[index]), RECT{tile.left + scale(window, 12), tile.top + scale(window, 28),
                                                      tile.right - scale(window, 8), tile.bottom - scale(window, 4)});
    }
}

void layoutHistory(HWND window, const RECT &content) {
    const int gap = densitySpace(window, 18, visualDensity.section_spacing), row = scale(window, 34);
    const int heroBottom = layoutHero(window, content, scale(window, 168), jsti::chrome::Gradient::brand);
    place(window, importID, box(frame.hero.right - scale(window, 26) - scale(window, 124), frame.hero.top + scale(window, 24),
                                scale(window, 124), row));
    place(window, historyClearID, box(frame.hero.right - scale(window, 294), frame.hero.top + scale(window, 24),
                                     scale(window, 136), row));
    layoutChips(window, {{historySessionsID, L"Sessions"}, {historyErrorsID, L"Errors"},
                         {historyAverageID, L"Average Length"}, {historySpendID, L"Spend"}});

    // The detail card stacks a header row, a variant picker, the transcript and four
    // rows of action buttons, with the search row above it all. At the window's
    // minimum size there used to be no slack left for any of that, which collapsed
    // the transcript to zero height (#1218). Every row and every painted region
    // keeps its full, non-overlapping size always; only pure whitespace -- between
    // the search row and its neighbours, and inside the detail card -- compresses,
    // and only by as much as is needed to guarantee a readable (three-line)
    // transcript, so normal and larger windows render exactly as before -- this
    // only engages once the card is genuinely too short. Both the search-row gaps
    // and the detail card's internal gaps share one global shrink factor, derived
    // below from the two end states (everything full-size vs. everything at its
    // floor), so the result stays a simple linear interpolation with no circular
    // dependency even though squeezing the search-row gaps also changes how much
    // vertical space the detail card itself gets.
    struct Gap { int full, floor; };
    const Gap beforeSearch{scale(window, 14), scale(window, 4)};
    const Gap afterSearch{scale(window, 14), scale(window, 4)};
    // The card's painted title/icon tile occupies its top scale(18)..scale(54);
    // beforeHeader must never shrink below that or historyDetailID paints over it,
    // so it keeps its full spacing and contributes nothing to the squeeze budget.
    const Gap beforeHeader{scale(window, 58), scale(window, 58)};
    const Gap afterHeader{scale(window, 40), row + scale(window, 2)};
    const Gap afterVariant{row + scale(window, 10), row + scale(window, 4)};
    const Gap beforeActions{scale(window, 10), scale(window, 3)};
    const Gap actionRowGap{scale(window, 8), scale(window, 3)};
    const Gap playbackGap{scale(window, 26), scale(window, 20)};
    const Gap insetV{scale(window, 20), scale(window, 8)};

    const int listWidth = (widthOf(content) - gap) * 13 / 25;
    const int detailLeft = content.left + listWidth + gap, detailRight = content.right;
    const int left = detailLeft + scale(window, 20), right = detailRight - scale(window, 20);

    const int localFull = beforeHeader.full + afterHeader.full + afterVariant.full + beforeActions.full +
                          4 * row + 3 * actionRowGap.full + playbackGap.full + insetV.full;
    const int localFloor = beforeHeader.floor + afterHeader.floor + afterVariant.floor + beforeActions.floor +
                           4 * row + 3 * actionRowGap.floor + playbackGap.floor + insetV.floor;
    const int upstreamFull = beforeSearch.full + row + afterSearch.full;
    const int upstreamFloor = beforeSearch.floor + row + afterSearch.floor;

    // transcriptID's font is set to Font::mono in refreshFont(), not Font::body;
    // measuring with the actual control font keeps this guarantee honest (#1218).
    HDC metricsDC = GetDC(window);
    const int lineHeight = jsti::chrome::measure(metricsDC, L"Ag", right - left, jsti::chrome::Font::mono, GetDpiForWindow(window));
    ReleaseDC(window, metricsDC);
    const int minTranscript = 3 * lineHeight + scale(window, 16);

    const int availableFull = content.bottom - (heroBottom + upstreamFull);
    const int availableFloor = content.bottom - (heroBottom + upstreamFloor);
    const int transcriptAtFull = availableFull - localFull;
    const int transcriptAtFloor = availableFloor - localFloor;
    const int compressibleTotal = transcriptAtFloor - transcriptAtFull;
    const double shrink = transcriptAtFull >= minTranscript || compressibleTotal <= 0
                             ? 0.0
                             : std::min(1.0, double(minTranscript - transcriptAtFull) / compressibleTotal);
    // Rounds the reduction up (not down) so every squeezed gap is never larger than
    // its continuous target -- otherwise truncation could leave the transcript a
    // few pixels short of minTranscript even though shrink reached 1.0.
    auto squeeze = [&](Gap g) {
        const double reduction = (g.full - g.floor) * shrink;
        const int truncated = static_cast<int>(reduction);
        return g.full - (truncated < reduction ? truncated + 1 : truncated);
    };

    const int searchTop = heroBottom + squeeze(beforeSearch);
    place(window, searchLabelID, box(content.left, searchTop + scale(window, 8), scale(window, 112), scale(window, 20)));
    placeField(window, searchID, RECT{content.left + scale(window, 116), searchTop,
                                      content.right - scale(window, 216), searchTop + row});
    place(window, historyFiltersID, box(content.right - scale(window, 208), searchTop, scale(window, 120), row));
    place(window, clearSearchID, box(content.right - scale(window, 80), searchTop, scale(window, 80), row));
    const int top = searchTop + row + squeeze(afterSearch);
    place(window, 93, box(content.left, top, listWidth, scale(window, 20)));
    place(window, historyID, RECT{content.left, top + scale(window, 22), content.left + listWidth, content.bottom});
    const RECT detail{detailLeft, top, detailRight, content.bottom};
    addCard(detail, 0xE8A5, L"Selected recording");

    const int squeezedActionRowGap = squeeze(actionRowGap), squeezedPlaybackGap = squeeze(playbackGap);
    const int actionsHeight = 4 * row + 3 * squeezedActionRowGap + squeezedPlaybackGap;
    const int squeezedInsetV = squeeze(insetV);

    int y = detail.top + squeeze(beforeHeader);
    place(window, historyDetailID, RECT{left, y, right, y + row});
    y += squeeze(afterHeader);
    place(window, variantLabelID, box(left, y + scale(window, 7), scale(window, 128), scale(window, 20)));
    place(window, variantID, RECT{left + scale(window, 132), y, right, y + scale(window, 200)});
    y += squeeze(afterVariant);
    placeField(window, transcriptID, RECT{left, y, right, detail.bottom - squeezedInsetV - actionsHeight - squeeze(beforeActions)}, true);
    int actions = detail.bottom - squeezedInsetV - actionsHeight;
    place(window, playbackLabelID, box(left, actions, scale(window, 80), scale(window, 20)));
    place(window, playbackTimeID, RECT{left + scale(window, 84), actions, right, actions + scale(window, 20)});
    actions += squeezedPlaybackGap;
    auto cell = [&](int index, int top, int columns) {
        const int width = (right - left - (columns - 1) * scale(window, 8)) / columns;
        return box(left + index * (width + scale(window, 8)), top, width, row);
    };
    place(window, playPauseID, cell(0, actions, 3));
    place(window, stopPlaybackID, cell(1, actions, 3));
    place(window, copyID, cell(2, actions, 3));
    // A third of the card is too narrow for "Copy transcript"; the Mac says Copy here too.
    setLabel(window, copyID, L"&Copy");
    actions += row + squeezedActionRowGap;
    place(window, readAloudID, cell(0, actions, 2));
    place(window, retryID, cell(1, actions, 2));
    actions += row + squeezedActionRowGap;
    place(window, exportID, cell(0, actions, 3));
    place(window, openAudioID, cell(1, actions, 3));
    place(window, historyCorrectionsID, cell(2, actions, 3));
    setLabel(window, exportID, L"&Export...");
    actions += row + squeezedActionRowGap;
    place(window, historyDeleteID, cell(0, actions, 3));
    const RECT issueStart = cell(1, actions, 3);
    place(window, issueReportID, RECT{issueStart.left, actions, right, actions + row});
}

// A settings card: `rows` controls, top to bottom, with a description.
int layoutSettingsCard(HWND window, int top, const RECT &content, wchar_t glyph, const std::wstring &title,
                       const std::wstring &description, int contentHeight) {
    const int inset = densitySpace(window, 22, visualDensity.card_padding);
    HDC dc = GetDC(window);
    const int textHeight = description.empty() ? 0 : jsti::chrome::measure(dc, description,
        widthOf(content) - 2 * inset, jsti::chrome::Font::body, GetDpiForWindow(window));
    ReleaseDC(window, dc);
    const int descriptionGap = densitySpace(window, 12, visualDensity.content_spacing);
    const int height = cardHeaderHeight(window) + textHeight + (textHeight ? descriptionGap : 0) +
        contentHeight + densitySpace(window, 20, visualDensity.card_padding);
    const RECT card = box(content.left, top, widthOf(content), height);
    addCard(card, glyph, title);
    if (!description.empty()) {
        frame.paragraphs.push_back({box(card.left + inset, card.top + cardHeaderHeight(window) - scale(window, 2),
                                        widthOf(card) - 2 * inset,
                                        textHeight), description, jsti::chrome::Font::body, true});
    }
    return card.top + cardHeaderHeight(window) + textHeight + (textHeight ? descriptionGap : 0);
}

void layoutSettings(HWND window, const RECT &content) {
    SetDlgItemTextW(window, configurationID, state.page == correctionsPage ?
        L"Learning &preferences..." : L"Dictation &preferences...");
    const int gap = densitySpace(window, 18, visualDensity.section_spacing), row = scale(window, 34);
    const int inset = densitySpace(window, 22, visualDensity.card_padding);
    const bool voice = state.page == voicePage;
    int top = layoutHero(window, content, scale(window, voice ? 132 : 120),
                         voice ? jsti::chrome::Gradient::voice : jsti::chrome::Gradient::settings) + gap;
    const int left = content.left + inset, right = content.right - inset;
    auto label = [&](int identifier, int y) { place(window, identifier, box(left, y + scale(window, 7), scale(window, 180), scale(window, 20))); };
    auto control = [&](int identifier, int y, int width = 0) {
        place(window, identifier, RECT{left + scale(window, 188), y, width ? left + scale(window, 188) + width : right,
                                       y + (identifier == modelID || identifier == microphoneID || identifier == sourceID ||
                                            identifier == modeID || identifier == appearanceID ? scale(window, 240) : row)});
    };
    auto button = [&](int identifier, int y, int width) { place(window, identifier, box(right - width, y, width, row)); };
    switch (state.page) {
    case voicePage: {
        int y = layoutSettingsCard(window, top, content, 0xE767, L"Read aloud",
            L"Read the selected History transcript, or open Text and export for typed/pasted text and an explicit "
            L"clipboard snapshot. The selected voice provider uses its saved key. External selected text is unavailable.", 2 * row + gap);
        place(window, voiceSettingsID, box(left, y, scale(window, 150), row));
        button(readAloudID, y, scale(window, 196));
        place(window, stopPlaybackID, box(right - scale(window, 196) - scale(window, 8) - scale(window, 96), y,
                                          scale(window, 96), row));
        place(window, voiceSourcesID, box(left, y + row + gap, scale(window, 260), row));
        place(window, voiceCredentialID, box(right - scale(window, 190), y + row + gap, scale(window, 190), row));
        break;
    }
    case generalPage: {
        // Output used to have its own card; it now shares this card's header
        // (the configuration action) and backup row (the text-output button),
        // so the page fits the minimum height without the App behaviour card
        // falling outside the window bounds.
        const int cardTop = top;
        int y = layoutSettingsCard(window, top, content, 0xE720, L"Audio, output and backup",
            L"Finished text goes to the starting app or clipboard. "
            L"ZIPs can include audio and app profiles with prompts; they are unencrypted. "
            L"Settings and credentials are excluded.",
            2 * row + scale(window, 12));
        place(window, configurationID, box(right - scale(window, 220),
            cardTop + densitySpace(window, 16, visualDensity.card_padding), scale(window, 220), row));
        // Restore sits above Save ZIP backup so the page keeps its minimum height.
        label(94, y); control(microphoneID, y, right - left - scale(window, 188 + 176 + 12));
        button(backupRestoreID, y, scale(window, 176));
        const int backupY = y + row + scale(window, 12);
        place(window, textOutputID, box(left, backupY, scale(window, 170), row));
        place(window, backupAudioID, RECT{
            left + scale(window, 182), backupY, left + scale(window, 308), backupY + row});
        place(window, backupProfilesID, RECT{
            left + scale(window, 320), backupY, right - scale(window, 188), backupY + row});
        button(backupExportID, backupY, scale(window, 176));
        top = y + 2 * row + scale(window, 12) + densitySpace(window, 20, visualDensity.card_padding) + gap;
        // The Mac's App Behaviour card. The note appears only when the system
        // decides Launch at login, so the page still fits the minimum height.
        y = layoutSettingsCard(window, top, content, 0xE713, L"App behaviour", state.loginItemNote,
                               3 * row + scale(window, 24));
        label(appearanceLabelID, y); control(appearanceID, y, scale(window, 220));
        place(window, loginItemID, RECT{left + scale(window, 188 + 220 + 24), y, right, y + row});
        place(window, automationID, RECT{left, y + row + scale(window, 12), right - scale(window, 232),
                                         y + 2 * row + scale(window, 12)});
        place(window, automationSettingsID, box(right - scale(window, 220), y + row + scale(window, 12),
                                                scale(window, 220), row));
        label(recordingsFolderLabelID, y + 2 * row + scale(window, 24));
        control(recordingsFolderID, y + 2 * row + scale(window, 24), scale(window, 110));
        place(window, audioCleanupID, RECT{
            left + scale(window, 188 + 110 + 12), y + 2 * row + scale(window, 24),
            right - scale(window, 172), y + 3 * row + scale(window, 24)});
        button(backupInspectID, y + 2 * row + scale(window, 24), scale(window, 160));
        break;
    }
    case transcriptionPage: {
        auto shown = [](int identifier) { const auto found = state.wanted.find(identifier);
                                          return found == state.wanted.end() || found->second; };
        const bool source = shown(sourceID), mode = shown(modeID);
        const int rows = 4 + (source ? 1 : 0) + (mode ? 1 : 0);
        int y = layoutSettingsCard(window, top, content, 0xE720, L"Model", L"",
                                   rows * row + (rows - 1) * scale(window, 12) + scale(window, 12));
        if (source) { label(sourceLabelID, y); control(sourceID, y); y += row + scale(window, 12); }
        else place(window, sourceLabelID, box(left, y, 1, 1));
        if (mode) { label(95, y); control(modeID, y); y += row + scale(window, 12); }
        label(90, y); control(modelID, y); y += row + scale(window, 12);
        place(window, modelStatusID, RECT{left, y, right - scale(window, 180), y + row + scale(window, 12)});
        button(modelRefreshID, y, scale(window, 168)); button(localModelsID, y, scale(window, 168));
        y += row + scale(window, 24);
        label(91, y);
        placeField(window, keyID, RECT{left + scale(window, 188), y, right - scale(window, 252), y + row});
        place(window, saveID, box(right - scale(window, 240), y, scale(window, 112), row));
        button(apiKeysID, y, scale(window, 116));
        y += row + scale(window, 12);
        place(window, azureID, box(left + scale(window, 188), y, scale(window, 240), row));
        place(window, configurationID, box(right - scale(window, 220), y, scale(window, 220), row));
        top = y + row + densitySpace(window, 20, visualDensity.card_padding) + gap;
        y = layoutSettingsCard(window, top, content, 0xE9D2, L"Compare Models",
            L"Run the same audio through several models, rank the raw results blind, and export the scoreboard.", row);
        place(window, comparisonID, box(left, y, scale(window, 220), row));
        break;
    }
    case postProcessingPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE734, L"Clean-up",
            L"Send finished transcripts to an OpenRouter model to fix punctuation and filler, or follow your own "
            L"instructions. Empty recordings stay empty, and History keeps the original beside the result.", row);
        place(window, processingID, box(left, y, scale(window, 230), row));
        place(window, configurationID, box(left + scale(window, 242), y, scale(window, 220), row));
        break;
    }
    case correctionsPage: case pronunciationPage: {
        const bool corrections = state.page == correctionsPage;
        const int y = layoutSettingsCard(window, top, content, 0xE8D2,
            corrections ? L"Personal corrections" : L"Pronunciation dictionary",
            corrections
                ? L"Add canonical spellings and spoken variants, choose automatic, context or manual rules, "
                  L"and preview applied corrections and suggestions. Original provider text stays in History. "
                  L"Automatic observation of edits in other apps is not available on this platform."
                : L"Edit words, phonetic pronunciations and text replacements. Regular expressions, case sensitivity "
                  L"and entry order use the same matching as the Mac. Deepgram uses text replacements, not IPA tags.", row);
        place(window, corrections ? correctionsID : pronunciationID, box(left, y, scale(window, 230), row));
        if (corrections)
            place(window, configurationID, box(left + scale(window, 242), y, scale(window, 220), row));
        break;
    }
    case profilesPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE77B, L"Per-app profiles",
            L"A profile applies its model, language and clean-up prompt when you dictate into the apps it lists. "
            L"The recording keeps the profile it started with.", row);
        place(window, profilesID, box(left, y, scale(window, 190), row));
        break;
    }
    case keyboardPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE765, L"Shortcut",
            L"The shortcut works while another app is in front. Hold, double-tap or press to toggle, as you choose.",
            2 * row + scale(window, 52));
        place(window, shortcutValueID, RECT{left, y, right, y + scale(window, 28)});
        place(window, shortcutID, box(left, y + scale(window, 40), scale(window, 200), row));
        place(window, configurationID, box(left + scale(window, 212), y + scale(window, 40), scale(window, 220), row));
        place(window, actionShortcutsID, box(left, y + scale(window, 52) + row, scale(window, 200), row));
        break;
    }
    case cloudSyncPage: {
        const int y = layoutSettingsCard(window, top, content, 0xE753, L"iCloud",
            L"Sign in with your Apple ID to sync History with your Mac. Only transcripts sync; audio stays on the "
            L"device that recorded it. API keys can be imported from your Mac with its key-sync passphrase.", row);
        place(window, cloudSyncID, box(left, y, scale(window, 220), row));
        break;
    }
    default: break;
    }
}

void layoutAbout(HWND window, const RECT &content) {
    const int inset = densitySpace(window, 22, visualDensity.card_padding), row = scale(window, 34);
    const std::wstring note = L"Open source under the MIT licence. Your audio goes only to the provider you choose, "
        L"or stays on this PC with an on-device model.";
    HDC dc = GetDC(window);
    const int detailsWidth = widthOf(content) - 2 * inset;
    const int detailsHeight = jsti::chrome::measure(
        dc, state.aboutDetails, detailsWidth, jsti::chrome::Font::body, GetDpiForWindow(window)
    ) + scale(window, 12);
    const int noteHeight = jsti::chrome::measure(
        dc, note, detailsWidth, jsti::chrome::Font::body, GetDpiForWindow(window)
    );
    ReleaseDC(window, dc);
    const int gap = scale(window, 8);
    const int linkRows = (static_cast<int>(state.aboutLinks.size()) + 2) / 3;
    int y = layoutSettingsCard(window, content.top, content, 0xE946, L"About", L"",
        scale(window, 96) + noteHeight + detailsHeight + (linkRows + 2) * (row + gap));
    frame.icon = box(content.left + inset, y, scale(window, 72), scale(window, 72));
    frame.paragraphs.push_back({box(frame.icon.right + scale(window, 18), y + scale(window, 8), scale(window, 480),
                                    scale(window, 30)), L"Just Speak to It", jsti::chrome::Font::title, false});
    frame.paragraphs.push_back({box(frame.icon.right + scale(window, 18), y + scale(window, 38), scale(window, 480),
                                    scale(window, 22)), pageInfo[aboutPage].subtitle, jsti::chrome::Font::body, true});
    y += scale(window, 88);
    frame.paragraphs.push_back({box(content.left + inset, y, detailsWidth, noteHeight), note,
                                jsti::chrome::Font::body, false});
    y += noteHeight + gap;
    place(window, aboutDetailsID, box(content.left + inset, y, widthOf(content) - 2 * inset, detailsHeight));
    y += detailsHeight;
    const int linkWidth = (widthOf(content) - 2 * inset - 2 * gap) / 3;
    for (size_t i = 0; i < state.aboutLinks.size(); ++i)
        place(window, aboutLinkBaseID + static_cast<int>(i),
            box(content.left + inset + static_cast<int>(i % 3) * (linkWidth + gap),
                y + static_cast<int>(i / 3) * (row + gap), linkWidth, row));
    y += linkRows * (row + gap);
    place(window, setupGuideID, box(content.left + inset, y, scale(window, 192), row));
    place(window, permissionsID, box(content.left + inset + scale(window, 200), y, scale(window, 208), row));
    place(window, troubleshootingID, box(content.left + inset, y + row + gap, scale(window, 240), row));
}

bool settingsSearchOpen(HWND window) {
    return settingsSearch.active &&
        (!settingsSearch.shown.empty() || GetWindowTextLengthW(GetDlgItem(window, settingsSearchID)) > 0);
}

// Each results row: a semibold title over a caption detail.
int settingsResultHeight(HWND window) {
    const UINT dpi = GetDpiForWindow(window);
    HDC dc = GetDC(window);
    const int title = jsti::chrome::measure(dc, L"Ag", scale(window, 200), jsti::chrome::Font::bodySemibold, dpi);
    const int detail = jsti::chrome::measure(dc, L"Ag", scale(window, 200), jsti::chrome::Font::caption, dpi);
    ReleaseDC(window, dc);
    return title + detail + scale(window, 18);
}

// The search label, box and (while searching) the results or empty state, which
// take the pages' place. Returns where the Speak heading starts.
int layoutSettingsSearch(HWND window, int sidebarWidth, int bottom) {
    const UINT dpi = GetDpiForWindow(window);
    const int inner = sidebarWidth - scale(window, 44);
    HDC dc = GetDC(window);
    const int captionHeight = jsti::chrome::measure(dc, L"Search settings", inner, jsti::chrome::Font::caption, dpi);
    const int lineHeight = jsti::chrome::measure(dc, L"Ag", inner, jsti::chrome::Font::body, dpi);
    const int noMatchHeight = jsti::chrome::measure(dc, L"No settings match", inner, jsti::chrome::Font::caption, dpi);
    ReleaseDC(window, dc);
    int y = scale(window, 58);
    const RECT label = box(scale(window, 22), y, inner, captionHeight);
    place(window, settingsSearchLabelID, label);
    frame.searchHint = label;
    y += captionHeight + scale(window, 4);
    const int editHeight = std::max(scale(window, 20), lineHeight + scale(window, 2));
    const RECT field = box(scale(window, 12), y, sidebarWidth - scale(window, 24),
                           std::max(scale(window, 34), editHeight + scale(window, 14)));
    frame.fields.push_back(field);
    place(window, settingsSearchID, box(field.left + scale(window, 10), field.top + (heightOf(field) - editHeight) / 2,
                                        widthOf(field) - scale(window, 20), editHeight));
    y = field.bottom + scale(window, 12);
    place(window, settingsResultsID, RECT{scale(window, 10), y, sidebarWidth - scale(window, 10),
                                          std::max<int>(y + settingsResultHeight(window), bottom - scale(window, 12))});
    place(window, settingsNoMatchID, box(scale(window, 22), y, inner, noMatchHeight));
    return y;
}

void layout(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    frame = Frame{};
    const int sidebarWidth = measuredSidebarWidth(window);
    const int headerHeight = scale(window, 64), statusHeight = scale(window, 44);
    const int padding = densitySpace(window, 24, visualDensity.page_padding);
    frame.sidebar = RECT{0, 0, sidebarWidth, client.bottom};
    frame.header = RECT{sidebarWidth, 0, client.right, headerHeight};
    frame.status = RECT{sidebarWidth, client.bottom - statusHeight, client.right, client.bottom};
    // Sidebar: settings search, then Speak and Settings, as on the Mac. The
    // search label and box take their heights from the fonts at this DPI.
    const bool searchOpen = settingsSearchOpen(window);
    int y = layoutSettingsSearch(window, sidebarWidth, client.bottom);
    if (!searchOpen) frame.speakHeading = box(scale(window, 22), y, sidebarWidth - scale(window, 44), scale(window, 20));
    y += scale(window, 24);
    for (int page = 0; page < pageCount; ++page) {
        if (page == generalPage) {
            y += densitySpace(window, 10, visualDensity.section_spacing);
            if (!searchOpen)
                frame.settingsHeading = box(scale(window, 22), y, sidebarWidth - scale(window, 44), scale(window, 20));
            y += scale(window, 24);
        }
        const int rowHeight = densitySpace(window, 36, std::max(36, visualDensity.minimum_row_height));
        place(window, navBaseID + page, box(scale(window, 10), y, sidebarWidth - scale(window, 20), rowHeight));
        y += rowHeight + densitySpace(window, 2, 0);
    }
    // Header: Import and Record on every page but those that carry their own.
    const int buttonTop = (headerHeight - scale(window, 36)) / 2;
    if (state.page != dashboardPage) {
        place(window, recordID, box(client.right - padding - scale(window, 124), buttonTop, scale(window, 124), scale(window, 36)));
    }
    if (state.page != historyPage) {
        // Beside Record, or at the edge where the dashboard's hero carries Record.
        const int right = state.page == dashboardPage ? client.right - padding
                                                      : client.right - padding - scale(window, 124) - scale(window, 10);
        place(window, importID, box(right - scale(window, 140), buttonTop, scale(window, 140), scale(window, 36)));
    }
    place(window, statusID, RECT{sidebarWidth + padding, frame.status.top + scale(window, 12), client.right - padding,
                                 client.bottom - scale(window, 8)});
    const RECT content{sidebarWidth + padding, headerHeight + scale(window, 4), client.right - padding,
                       client.bottom - statusHeight - densitySpace(window, 18, visualDensity.section_spacing)};
    switch (state.page) {
    case dashboardPage: layoutDashboard(window, content); break;
    case historyPage: layoutHistory(window, content); break;
    case aboutPage: layoutAbout(window, content); break;
    default: layoutSettings(window, content); break;
    }
    applyVisibility(window);
    invalidateBackdrop(window);
}
} // namespace jsti_window
