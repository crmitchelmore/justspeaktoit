// The vocabulary editors (Corrections, Pronunciation, recording corrections,
// stored candidates and the legacy word dictionary): the editor's state and
// window procedure (WindowsVocabulary.cpp), its controls and layout
// (WindowsVocabularyControls.cpp) and the pieces the self-test
// (CWindowsSelfTest/WindowsVocabularySelfTest.cpp) drives. Not public ABI.
#pragma once

#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include <array>
#include <string>
#include <vector>

namespace jsti::vocabulary {

constexpr UINT update = WM_APP + 93;
enum { list = 900, add, save, remove, up, down, field = 910, preview = 920,
       previewTags, previewButton, notice, includeRules, includeTags, tags, preferences, defaults,
       search = 930, categoryFilter = 931, importMerge = 934, importReplace, exportJSON,
       reviewCandidates = 960, promoteCandidate, dismissCandidate, clearCandidates, allowLearning, stopLearning,
       legacyDictionary };
using Row = std::array<std::string, 8>;
struct Category { std::string value; size_t count; };
struct Dialog {
    int kind = 0, selected = -1, scroll = 0;
    HWND window = nullptr;
    HWND categoryLabel = nullptr;
    HFONT font = nullptr;
    bool busy = true;
    std::string category;
    std::vector<Category> categories;
    std::vector<HWND> controls;
    std::vector<Row> rows;
    std::vector<int> visible;
    void (*emit)(int, const char *, int) = nullptr;
};
struct Update { std::string payload; bool refresh; };

// Payload codec shared with the host: tabs, newlines and percent signs are escaped.
std::string escaped(const std::string &text);
std::string decoded(const std::string &text);
std::vector<std::string> split(const std::string &text, char delimiter);

// Controls (WindowsVocabularyControls.cpp). UI thread only.
void set(HWND window, int id, const std::string &text);
std::string get(HWND window, int id);
std::string value(Dialog &d, int index);
void fill(Dialog &d, const Row &row);
void updateCategories(Dialog &d, std::vector<Category> options);
void layout(Dialog &d);
bool updateFont(Dialog &d);
bool createControls(Dialog &d);

// The editor (WindowsVocabulary.cpp). UI thread only.
void pending(Dialog &d, bool busy);
void action(Dialog &d, const char *name);
HWND createWindow(HWND owner, Dialog &dialog);
// Makes `window` the editor jsti_vocabulary_set delivers `kind` updates to.
// Its WM_DESTROY clears it again and frees any update still queued for it.
void activateEditor(HWND window, int kind);

} // namespace jsti::vocabulary
