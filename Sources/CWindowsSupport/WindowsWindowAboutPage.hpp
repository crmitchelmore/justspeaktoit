// About page state, owned by WindowsWindowAbout.cpp. Other window files read it
// through aboutState(); only jsti_window_configure_about writes it, before the
// window runs.
#pragma once

#include "WindowsWindowInternal.hpp"

namespace jsti_window {

struct AboutLink { std::wstring title, url; };
struct AboutPageState {
    std::wstring aboutDetails = L"Build metadata has not been supplied by this host.";
    std::vector<AboutLink> aboutLinks;
};

const AboutPageState &aboutState();

} // namespace jsti_window
