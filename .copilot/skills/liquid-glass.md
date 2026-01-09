---
name: liquid-glass
description: Guidance for adopting Apple's Liquid Glass design language accurately (principles + SwiftUI usage patterns). Use when designing iOS/iPadOS/macOS UI that should match Apple's Liquid Glass look and behavior.
compatibility: iOS/iPadOS/macOS (Liquid Glass-era SDKs); SwiftUI-first; UIKit/AppKit notes included.
allowed-tools: Read
metadata:
  author: timsearle
  version: "1.0"
---

# Liquid Glass (Apple) adoption skill

Use this skill when the user asks you to adopt **Apple Liquid Glass** (design + implementation) or mentions `glassEffect`, `GlassEffectContainer`, translucent navigation layers, floating toolbars/tab bars, or "new Apple design system".

## High-level rule (don't get this wrong)

**Liquid Glass is for the navigation / controls layer that floats above content — not the content layer.**
- ✅ Use for: toolbars, navigation bars, tab bars, floating control clusters, sheets/popovers/menus.
- ❌ Avoid for: lists, tables, primary reading surfaces, media/content itself, and stacked "glass-on-glass".

## Sources of truth (use these first)

Prefer **official Apple docs** for names/availability and behavior:
- Liquid Glass overview (Apple Developer Documentation):
  - https://docs.developer.apple.com/documentation/technologyoverviews/liquid-glass
- Adopting Liquid Glass (Apple Developer Documentation):
  - https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- SwiftUI: `GlassEffectContainer` and related APIs (Apple Developer Documentation):
  - https://developer.apple.com/documentation/swiftui/glasseffectcontainer
  - https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)

Cross-reference community notes (helpful, but treat as secondary):
- LiquidGlassReference (Conor Luddy): https://github.com/conorluddy/LiquidGlassReference

## Design principles (how to "feel" like Liquid Glass)

When generating UI/design guidance:
1. **Hierarchy by depth**: content reads as the base plane; controls float above with translucency and subtle depth.
2. **Legibility first**: glass is only "beautiful" if foreground controls remain readable over arbitrary content.
3. **Use system standard components**: the system applies the correct sampling, vibrancy, motion, and accessibility adaptations.
4. **Avoid extra custom backgrounds** on navigation/toolbar/sheet surfaces unless you are intentionally opting out.

## SwiftUI implementation conventions

### 1) Prefer automatic adoption
If the app uses standard SwiftUI structures (e.g., `NavigationStack`, `TabView`, toolbars, sheets), default to **removing custom backgrounds** and letting the system apply Liquid Glass.

- If you see legacy code like `.toolbarBackground(...)`, `.presentationBackground(...)`, heavy `.background(Color...)` on navigation chrome, prefer removing/relaxing it for Liquid Glass-era SDKs.

### 1a) Toolbars: new Liquid Glass behaviors (grouping + icons)
In Liquid Glass-era SDKs, **toolbars adopt Liquid Glass** and introduce a stronger **grouping mechanism** for toolbar items (items in the same group share a single glass background).

Conventions (from Apple's "Adopting Liquid Glass" guidance):
- **Group related actions together** (similar actions, or actions affecting the same UI) and keep groupings consistent across platforms.
- **Separate groups intentionally** using a *fixed spacer* between groups (SwiftUI: `ToolbarSpacer` / fixed spacing where available).
  - Toolbars overview: https://developer.apple.com/documentation/swiftui/toolbars
- **Prefer standard icons (SF Symbols) for common actions** instead of text to declutter.
- **Don't mix text and icons inside the same shared-background group** (it looks inconsistent).
- **Always provide accessibility labels** for icon-only controls (prefer `Label` or add `.accessibilityLabel`).
- **Audit toolbar customizations** (custom spacers, custom backgrounds, or unusual item layouts) because they often fight system grouping/placement.
- **Hide the toolbar item, not the view inside it**. If you need something to disappear, hide the entire toolbar item using the appropriate API:
  - SwiftUI: https://developer.apple.com/documentation/swiftui/toolbarcontent/hidden(_:)

If you need to opt an item out of the shared glass background (creating its own grouping), use:
- https://developer.apple.com/documentation/swiftui/toolbarcontent/sharedbackgroundvisibility(_:)

### 2) Applying glass to custom controls
If you must build custom floating controls, apply glass using the SwiftUI Liquid Glass APIs (names per Apple docs):
- Use `.glassEffect(...)` on the control view.
- Use `GlassEffectContainer { ... }` when multiple glass elements belong together.

**Critical rule:** avoid separate glass elements sampling each other; group related glass in a container so the system can create a shared sampling region.

### 3) Grouping + morphing
For morphing/merging glass shapes (menus expanding/collapsing, clustered buttons, etc.):
- Put all related elements inside a single `GlassEffectContainer`.
- Use a shared `@Namespace` and apply `.glassEffectID(_:in:)` to each morphing element.
- Animate state transitions (prefer systemy spring/bouncy timing rather than constant animations).

### 4) Tinting
Tint is a semantic tool, not decoration:
- ✅ Use tint for primary/critical actions or state emphasis.
- ❌ Don't tint everything (it destroys hierarchy and reduces the "Apple" feel).

### 5) Clear vs regular
If your SDK supports variants (commonly described as "regular" vs "clear" styles), choose:
- **Regular** as the default.
- **Clear** only for controls over media-rich backgrounds, and only if legibility is preserved (often requiring dimming/contrast management behind the control).

If uncertain, use the default/regular style.

## UIKit/AppKit guidance (accuracy guardrails)

- Do **not** invent/assume UIKit classes like `UIGlassEffect` or `UIGlassContainerEffect` unless you can cite official Apple documentation for them.
- In UIKit/AppKit, prefer system-provided materials and visual effect views (e.g., `UIVisualEffectView` + `UIBlurEffect`) and rely on standard bars/sheets for best results.
- If the user needs true Liquid Glass fidelity, recommend **SwiftUI + standard components** on the appropriate OS versions.

## Accessibility requirements
When advising or generating UI:
- Assume users may enable **Reduce Transparency**, **Increase Contrast**, and **Reduce Motion**.
- Prefer system components because they automatically adapt.
- Never hard-code opacity/contrast in a way that defeats accessibility settings.

## Performance requirements
- Treat glass as GPU-expensive.
- Prefer fewer, larger glass surfaces rather than many small independent ones.
- Group related controls in a `GlassEffectContainer` to reduce redundant sampling.
- Avoid continuous animations "just to show glass". Let it rest.

## Review checklist (use before you say "done")

1. Is glass limited to navigation/controls rather than content?
2. Are there any glass-on-glass stacks? (remove)
3. Are custom backgrounds on toolbars/nav bars/sheets blocking automatic system behavior?
4. Are grouped controls inside a `GlassEffectContainer`?
5. Is tint used sparingly and semantically?
6. Have you considered Reduce Transparency/Reduce Motion/High Contrast?
7. Have you considered low-end device performance and battery?

## Output style when using this skill

When you respond to a user:
- Start with a short "what to change" list (remove custom backgrounds, prefer system components, add container, etc.).
- Provide a minimal SwiftUI snippet only where it clarifies the approach.
- If the user asks for exact API signatures/availability, defer to Apple docs URLs above and explicitly label anything else as "unverified".
