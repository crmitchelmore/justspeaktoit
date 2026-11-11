// Window snapshots: renders a window to a bitmap file for screenshots and the tour.
#include "WindowsWindowInternal.hpp"

int jsti_window_save_snapshot(const char *path, char *error, size_t errorCapacity) {
    HWND window;
    { std::lock_guard<std::mutex> lock(state.mutex); window = state.window; }
    extern int jsti_owned_window_save_snapshot(HWND, const char *, char *, size_t);
    return jsti_owned_window_save_snapshot(window, path, error, errorCapacity);
}

int jsti_owned_window_save_snapshot(HWND window, const char *path, char *error, size_t errorCapacity) {
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    if (process != GetCurrentProcessId()) {
        return jsti::fail("Only an app-owned native window can be captured.", error, errorCapacity);
    }
    if (!window || GetWindowThreadProcessId(window, nullptr) != GetCurrentThreadId()) {
        return jsti::fail("The native snapshot must run on the UI thread after READY.", error, errorCapacity);
    }
    std::wstring filename;
    if (!jsti::wide(path, filename) || filename.empty()) {
        return jsti::fail("No valid native snapshot path supplied.", error, errorCapacity);
    }
    RECT bounds{};
    if (!GetClientRect(window, &bounds)) {
        return jsti::fail(jsti::systemError("Measuring the native window"), error, errorCapacity);
    }
    const LONG width = bounds.right - bounds.left;
    const LONG height = bounds.bottom - bounds.top;
    const int64_t pixelBytes = static_cast<int64_t>(width) * height * 4;
    if (width <= 0 || height <= 0 || width > 8192 || height > 8192 || pixelBytes > 64 * 1024 * 1024) {
        return jsti::fail("Native snapshot dimensions exceed the 64 MiB diagnostic limit.", error, errorCapacity);
    }
    // Only this app's own client DC is acquired. Never use GetDC(nullptr),
    // desktop BitBlt, or another process's window handle here.
    struct BitmapResources {
        HWND window;
        HDC source = nullptr;
        HDC memory = nullptr;
        HBITMAP bitmap = nullptr;
        HGDIOBJ previous = nullptr;
        explicit BitmapResources(HWND window) : window(window) {}
        ~BitmapResources() {
            if (previous && previous != HGDI_ERROR) SelectObject(memory, previous);
            if (bitmap) DeleteObject(bitmap);
            if (memory) DeleteDC(memory);
            if (source) ReleaseDC(window, source);
        }
    } resources(window);
    resources.source = GetDC(window);
    if (!resources.source) return jsti::fail(jsti::systemError("Opening the native window DC"), error, errorCapacity);
    resources.memory = CreateCompatibleDC(resources.source);
    if (!resources.memory) return jsti::fail(jsti::systemError("Creating the snapshot DC"), error, errorCapacity);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height; // Top-down DIB; no extra pixel-copy buffer.
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    info.bmiHeader.biSizeImage = static_cast<DWORD>(pixelBytes);
    void *pixels = nullptr;
    resources.bitmap = CreateDIBSection(resources.source, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!resources.bitmap || !pixels) {
        return jsti::fail(jsti::systemError("Allocating the native snapshot bitmap"), error, errorCapacity);
    }
    resources.previous = SelectObject(resources.memory, resources.bitmap);
    if (!resources.previous || resources.previous == HGDI_ERROR) {
        return jsti::fail(jsti::systemError("Selecting the snapshot bitmap"), error, errorCapacity);
    }
    PatBlt(resources.memory, 0, 0, width, height, WHITENESS);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    if (!PrintWindow(window, resources.memory, PW_CLIENTONLY)) {
        return jsti::fail(jsti::systemError("Rendering the native window snapshot"), error, errorCapacity);
    }
    // Native children render into the same app-owned client bitmap even when a
    // runner's window compositor is headless. This never samples desktop pixels.
    const int savedDC = SaveDC(resources.memory);
    RECT windowBounds{};
    POINT clientOrigin{};
    if (!savedDC || !GetWindowRect(window, &windowBounds) || !ClientToScreen(window, &clientOrigin) ||
        !SetViewportOrgEx(resources.memory, windowBounds.left - clientOrigin.x,
            windowBounds.top - clientOrigin.y, nullptr)) {
        if (savedDC) RestoreDC(resources.memory, savedDC);
        return jsti::fail(jsti::systemError("Aligning the native client snapshot"), error, errorCapacity);
    }
    SendMessageW(window, WM_PRINT, reinterpret_cast<WPARAM>(resources.memory),
        PRF_CLIENT | PRF_CHILDREN | PRF_ERASEBKGND);
    RestoreDC(resources.memory, savedDC);
    if (!GdiFlush()) return jsti::fail(jsti::systemError("Completing native snapshot drawing"), error, errorCapacity);
    const auto *values = static_cast<const uint32_t *>(pixels);
    const uint32_t first = values[0] & 0x00FFFFFF;
    bool varied = false;
    for (size_t i = 1; i < static_cast<size_t>(pixelBytes / 4); ++i) {
        if ((values[i] & 0x00FFFFFF) != first) { varied = true; break; }
    }
    if (!varied) return jsti::fail("Windows returned a blank native window snapshot.", error, errorCapacity);
    BITMAPFILEHEADER header{};
    header.bfType = 0x4D42;
    header.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
    header.bfSize = header.bfOffBits + static_cast<DWORD>(pixelBytes);
    jsti::Handle file;
    file.value = CreateFileW(filename.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file.value == INVALID_HANDLE_VALUE) {
        return jsti::fail(jsti::systemError("Creating the native snapshot file"), error, errorCapacity);
    }
    auto write = [&](const void *bytes, DWORD count) {
        DWORD written = 0;
        return WriteFile(file.value, bytes, count, &written, nullptr) && written == count;
    };
    if (!write(&header, sizeof(header)) || !write(&info.bmiHeader, sizeof(info.bmiHeader)) ||
        !write(pixels, static_cast<DWORD>(pixelBytes)) || !FlushFileBuffers(file.value)) {
        return jsti::fail(jsti::systemError("Writing the native snapshot file"), error, errorCapacity);
    }
    return 0;
}

