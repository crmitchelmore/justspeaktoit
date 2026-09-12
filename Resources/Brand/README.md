# Just Speak to It identity

A five-bar waveform, centred and optically balanced, on the shared app orange
palette. Large, simple shapes stay legible at Dock, tab and Home Screen sizes.

Run from the repository root using Apple's toolchain:

    xcrun swift scripts/generate-icon.swift
    node --test scripts/tests/brand-assets.test.mjs

The generator is the canonical geometry and export recipe. The adjacent SVGs
are generated editable vector exports for standard, dark and tinted artwork.
Do not hand-edit derived PNGs.

- Mac: every 16–512 point size at 1x and 2x, including 1024 pixels, packaged in
  Resources/AppIcon.icns. The 64px inset and transparent rounded corners are
  specific to Mac. Finder, the Dock and onboarding use the same multi-resolution
  artwork. A generated copy in Sources/SpeakApp/Resources supports SwiftPM runs;
  the asset test verifies that both copies remain byte-identical.
- iPhone/iPad: opaque 1024px standard, dark and monochrome tinted variants.
  The OS supplies the rounded mask; artwork has no transparent corners.
- Watch: opaque 1024px source, with the waveform inside the circular safe area.
  Bundled when the existing Watch feature flag is enabled.
- Launch mark: adaptive vectors with matching waveform proportions.
- Web: SVG favicon/brand mark, 32px PNG fallback, 180px Apple touch icon, and
  192/512px manifest icons with a safe area for system masks.

Exports use sRGB. Raster sizes are drawn directly to explicit pixel buffers,
independent of display scale.

Apple reference: [Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon).
