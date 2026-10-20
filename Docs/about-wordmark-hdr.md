# About wordmark HDR

The macOS About title alone uses the existing semantic primary colour with
`Color.exposureAdjust(log2(1.5))` on macOS 26 or later, in standard-contrast dark
appearance with Reduce Transparency disabled. Older systems, light appearance,
increased contrast and Reduce Transparency retain the original unmodified text.
The app icon, navigation, controls, other text and other platforms are unchanged.

`View.allowedDynamicRange(.constrainedHigh)` is applied only to that title. This
is a real View modifier taking `Image.DynamicRange`, not a Color method. No
window/screen brightness or headroom override is installed. SwiftUI controls
display adaptation and tone mapping; actual luminance depends on display headroom.
This does not promise a fixed physical brightness or an HDR-capable screen.

## API and rendering verification

Verified against the Apple macOS 26.2 SDK using Apple Swift 6.2.3, including
typechecking with a macOS 14 deployment target. Apple's documentation confirms:

- [exposureAdjust](https://developer.apple.com/documentation/swiftui/color/exposureadjust(_:))
  scales linear-light components and adjusts HDR content headroom.
- [allowedDynamicRange](https://developer.apple.com/documentation/swiftui/view/alloweddynamicrange(_:))
  enables HDR rendering within the view hierarchy.
- [constrainedHigh](https://developer.apple.com/documentation/swiftui/image/dynamicrange/constrainedhigh)
  is suitable for HDR next to SDR content.

A native SwiftUI ImageRenderer probe using the same title styling and dark
environment in extended-linear mode produced a floating-point 16-bit image with
a maximum linear component of 1.2636719 (>1, genuine extended range). This is
rendering proof, not physical-display or full-app visual acceptance.
