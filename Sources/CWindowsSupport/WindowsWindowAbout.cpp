// About page: build details and links the host supplies before the window runs.
#include "WindowsWindowAboutPage.hpp"

namespace jsti_window {
namespace {
// Written under WindowState::mutex before the window runs; read-only afterwards.
AboutPageState about;
} // namespace

const AboutPageState &aboutState() { return about; }

} // namespace jsti_window

int jsti_window_configure_about(const char *details, const JSTIAboutLink *links, size_t count) {
    if (!details || !links || count == 0 || count > 8 || std::strlen(details) > 4096) return -1;
    std::wstring information;
    if (!jsti::wide(details, information) || information.empty()) return -1;
    std::vector<AboutLink> copied;
    for (size_t i = 0; i < count; ++i) {
        AboutLink link;
        if (!links[i].title || !links[i].url || std::strlen(links[i].title) > 128 ||
            std::strlen(links[i].url) > 2048 || !jsti::wide(links[i].title, link.title) ||
            !jsti::wide(links[i].url, link.url) || link.title.empty() ||
            link.title.find_first_of(L"\r\n\t") != std::wstring::npos ||
            link.url.compare(0, 8, L"https://") != 0 || link.url.size() <= 8 ||
            link.url.find_first_of(L" \r\n\t") != std::wstring::npos) return -1;
        copied.push_back(std::move(link));
    }
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.running) return -1;
    about.aboutDetails = std::move(information);
    about.aboutLinks = std::move(copied);
    return 0;
}
