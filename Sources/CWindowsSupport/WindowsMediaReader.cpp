#include "WindowsMediaReader.hpp"
#include <algorithm>

namespace jsti::media {

bool localPath(const char *text, std::wstring &path) {
    if (!jsti::wide(text, path) || path.size() > 32000) return false;
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.compare(0, 4, L"\\\\?\\") == 0) path.erase(0, 4);
    if (path.size() < 4 || !((path[0] >= L'A' && path[0] <= L'Z') ||
                            (path[0] >= L'a' && path[0] <= L'z')) ||
        path[1] != L':' || path[2] != L'\\' || path.find_first_of(L":\"<>|?*", 2) != std::wstring::npos) return false;
    size_t start = 3;
    while (start < path.size()) {
        const size_t end = path.find(L'\\', start);
        const auto part = path.substr(start, end == std::wstring::npos ? end : end - start);
        if (part.empty() || part == L"." || part == L".." || part.back() == L'.' || part.back() == L' ' ||
            std::any_of(part.begin(), part.end(), [](wchar_t ch) { return ch < 32; })) return false;
        if (end == std::wstring::npos) break;
        start = end + 1;
        if (start == path.size()) return false;
    }
    path.insert(0, L"\\\\?\\");
    return true;
}

} // namespace jsti::media
