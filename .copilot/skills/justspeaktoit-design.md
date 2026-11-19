---
name: justspeaktoit-design
description: Design system and philosophy for JustSpeakToIt brand. Use when creating web pages, marketing materials, UI components, or any visual assets for the JustSpeakToIt product.
compatibility: Web (HTML/CSS/JS), marketing materials, brand assets, native app UI (SwiftUI)
allowed-tools: Read, ApplyPatch, Bash
metadata:
  author: justspeaktoit
  version: "1.1"
---

# JustSpeakToIt Design System

Use this skill when creating **landing pages**, **marketing sites**, **web UI**, or **brand materials** for JustSpeakToIt. The design philosophy emphasizes **cinematic warmth**, **signal clarity**, and **tactile minimalism** while avoiding generic AI/tech aesthetics.

## Core Philosophy

### Anti-patterns to avoid (critical)
- ❌ **Purple/violet gradients** — overused in AI products, feels generic
- ❌ **Neon tech glow** — no cyberpunk blues or sci‑fi UI noise
- ❌ **Stock photo aesthetics** — people pointing at screens, fake smiles
- ❌ **Cluttered hero sections** — too many CTAs, competing messages
- ❌ **Electron/web-app feel** — our native apps deserve native-feeling marketing
- ❌ **Subscription-first messaging** — we're BYOK, lead with cost transparency

### Design principles (embody these)
1. **Signal clarity**: Voice is the hero—waveforms, rhythm, and flow should be visible
2. **Cinematic warmth**: Ember + saffron accents instead of sterile blues
3. **Trust by transparency**: Pricing, privacy, and tradeoffs are front and center
4. **Tactile minimalism**: Soft corners, subtle grain, and layered depth
5. **Motion as feedback**: Animation guides attention; never ornamental

## Color System

### Primary palette
The canonical tokens live in `landing-page/styles/tokens.css`, which mirrors the native colours in `Sources/SpeakCore/App/Apple/BrandColors.swift`. Read that file for the full set; the core dark values are:

```css
:root {
  /* Backgrounds */
  --ground: #121417;                 /* Page background */
  --ground-deep: #0d0f11;            /* Deepest bands */
  --surface: #191c21;                /* Cards and panels */
  --surface-2: #212630;              /* Raised surfaces */
  --line: rgba(255, 255, 255, .10);  /* Borders */

  /* Text */
  --text: #f5f3f0;                   /* Primary text, warm near-white */
  --text-dim: #adb4bd;               /* Secondary text */
  --text-faint: #868e98;             /* Tertiary text */

  /* Accent (ember + saffron) */
  --accent: #ff6b3d;                 /* Ember */
  --accent-warm: #ff9c4a;            /* Saffron */
  --accent-deep: #e3522e;            /* Ember deep */
  --accent-link: #ff9166;            /* Links on dark */

  /* Supporting */
  --lagoon: #2ed4bf;                 /* Lagoon teal for contrast */
  --lagoon-deep: #1aab99;
}
```

### Color usage rules
- **Accent (ember)**: Primary CTAs and core brand moments
- **Accent warm (saffron)**: Gradients and subtle highlights only
- **Lagoon**: Sparse contrast—use in small doses
- **Never**: Don't mix accent + lagoon in the same element unless it is a hero gradient

### Dark mode is default
The brand is dark-mode native. `tokens.css` also defines light values under `prefers-color-scheme: light` (for example `--ground: #f7f5f2`, `--accent: #c9461c` for contrast); use the tokens rather than hard-coded colours so both schemes work.

## Typography

### Font stack
```css
:root {
  /* Display/headings: Cabinet Grotesk - bold, confident */
  --display: "Cabinet Grotesk", ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;

  /* Body: General Sans - readable, friendly, professional */
  --body: "General Sans", ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
}
```

### Font loading
```html
<link rel="preconnect" href="https://api.fontshare.com">
<link rel="preconnect" href="https://cdn.fontshare.com" crossorigin>
<link href="https://api.fontshare.com/v2/css?f[]=cabinet-grotesk@700,800&f[]=general-sans@400,500,600&display=swap" rel="stylesheet">
```

### Type scale
| Element | Font | Weight | Size |
|---------|------|--------|------|
| Hero title | Cabinet Grotesk | 800 | clamp(2.75rem, 1.2rem + 5.6vw, 4.7rem) |
| Section title | Cabinet Grotesk | 800 | clamp(2rem, 5vw, 3rem) |
| Card title | Cabinet Grotesk | 700 | 1.25rem |
| Body | General Sans | 400-500 | 1rem |
| Small/muted | General Sans | 400 | 0.9rem |
| Eyebrow | General Sans | 600 | 0.85rem, uppercase, letter-spacing: 0.15em |

## Visual Elements

### The waveform motif
The animated waveform is a signature brand element representing voice/audio:
```css
.waveform-bar {
  width: 4px;
  background: linear-gradient(to top, var(--accent-deep), var(--accent-warm));
  border-radius: 4px;
  animation: wave 1.2s ease-in-out infinite;
}

@keyframes wave {
  0%, 100% { transform: scaleY(0.5); opacity: 0.6; }
  50% { transform: scaleY(1); opacity: 1; }
}
```

### Background orbs
Soft, blurred gradient orbs create depth without being distracting:
```css
.bg-orb {
  position: fixed;
  border-radius: 50%;
  filter: blur(100px);
  pointer-events: none;
  z-index: -1;
}
```
- Use sparingly (2-3 max per page)
- Animate slowly (20-30s float cycles)
- Keep opacity low (0.15-0.3)

### Grain texture
Subtle noise overlay adds warmth and prevents the "flat digital" look:
```css
body::before {
  content: '';
  position: fixed;
  inset: 0;
  background-image: url("data:image/svg+xml,..."); /* feTurbulence noise */
  opacity: 0.03;
  pointer-events: none;
}
```

### Card styling
```css
.card {
  background: var(--surface);
  border: 1px solid rgba(255, 255, 255, 0.06);
  border-radius: 20px;
  padding: 2rem;
  transition: all 0.4s cubic-bezier(0.19, 1, 0.22, 1);
}

.card:hover {
  transform: translateY(-5px);
  border-color: rgba(255, 255, 255, 0.12);
  box-shadow: 0 20px 40px rgba(0, 0, 0, 0.3);
}
```

## Animation Conventions

### Easing functions
```css
:root {
  --ease-out-expo: cubic-bezier(0.19, 1, 0.22, 1);  /* Smooth deceleration */
  --ease-spring: cubic-bezier(0.34, 1.56, 0.64, 1); /* Playful overshoot */
}
```

### Scroll reveal pattern
Elements should fade in and slide up as they enter the viewport:
```css
.reveal {
  opacity: 0;
  transform: translateY(40px);
  transition: all 0.8s var(--ease-out-expo);
}

.reveal.visible {
  opacity: 1;
  transform: translateY(0);
}
```

### Staggered animations
When multiple items animate, stagger them:
```javascript
elements.forEach((el, i) => {
  el.style.transitionDelay = `${i * 0.1}s`;
});
```

## Component Patterns

### Buttons
```css
.btn {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: 1rem 2rem;
  border-radius: 100px;  /* Fully rounded */
  font-weight: 600;
  transition: all 0.3s var(--ease-spring);
}

.btn--primary {
  background: linear-gradient(135deg, var(--accent) 0%, var(--accent-warm) 100%);
  color: var(--ground);
  box-shadow: 0 0 30px rgba(255, 107, 61, 0.32);
}

.btn--primary:hover {
  transform: translateY(-3px) scale(1.02);
  box-shadow: 0 0 50px rgba(255, 107, 61, 0.32);
}
```

### Badges/pills
```css
.badge {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  background: var(--surface);
  border: 1px solid rgba(255, 255, 255, 0.1);
  padding: 0.5rem 1rem;
  border-radius: 100px;
  font-size: 0.85rem;
  color: var(--text-dim);
}
```

### Section headers
```html
<div class="section-header">
  <div class="eyebrow">Features</div>
  <h2 class="title">Built for speed and privacy</h2>
  <p class="description">A native app that feels like magic.</p>
</div>
```

## Native App Theming (SwiftUI)

Apply a consistent accent color across macOS + iOS with the shared colours in `Sources/SpeakCore/App/Apple/BrandColors.swift` (`.brandAccent`, `.brandAccentWarm`, `.brandAccentDeep`, `.brandLagoon`, `.brandLagoonDeep`) rather than new literals:

```swift
ContentView()
  .tint(.brandAccent)
```

Guidelines:
- Use **accent only** for primary actions and selection states.
- Keep **destructive actions red** (system default).
- Prefer **system materials** and standard components over custom chrome.

## Liquid Glass (SwiftUI + AppKit)

Use Liquid Glass for **floating controls**, **HUDs**, and **navigation chrome**, not for primary content.

### SwiftUI essentials
```swift
Text("Hello")
  .padding()
  .glassEffect()

Text("Accent")
  .padding()
  .glassEffect(.regular.tint(.brandAccentWarm).interactive(), in: .rect(cornerRadius: 16))
```

Use containers to merge multiple glass elements:
```swift
GlassEffectContainer(spacing: 16) {
  HStack(spacing: 16) {
    Image(systemName: "mic.fill").glassEffect()
    Image(systemName: "doc.on.doc").glassEffect()
  }
}
```

Prefer system styles for buttons:
```swift
Button("Primary") { }
  .buttonStyle(.glassProminent)

Button("Secondary") { }
  .buttonStyle(.glass)
```

Key rules from Apple:
- Apply `.glassEffect` **after** layout/appearance modifiers.
- Use `.interactive()` for controls that should respond to touch/hover.
- Use `GlassEffectContainer` to improve performance and enable merging/morphing.
- Use `glassEffectID(_:in:)` when animating between states.

### AppKit essentials
```swift
let glassView = NSGlassEffectView(frame: frame)
glassView.cornerRadius = 16
glassView.tintColor = NSColor.systemOrange.withAlphaComponent(0.25)

let container = NSGlassEffectContainerView(frame: frame)
container.spacing = 40
```

AppKit rules:
- Use `NSGlassEffectContainerView` when multiple glass views are adjacent.
- Keep tint subtle and use rounded corners that match the app’s corner radius.

## Messaging Guidelines

### Voice and tone
- **Confident but not arrogant**: "The fastest way to..." not "The world's best..."
- **Direct but warm**: "Speak. We'll handle the rest." not "Revolutionary AI-powered..."
- **Honest about tradeoffs**: Acknowledge on-device vs cloud differences

### Key value propositions (in priority order)
1. **Speed**: Instant hotkey access, real-time transcription
2. **Privacy**: On-device option, your keys never touch our servers
3. **Cost transparency**: BYOK = ~$0.006/minute, no hidden fees
4. **Native quality**: SwiftUI, not Electron; menu bar, not browser tab

### Words to use
- Speak, voice, transcribe, text
- Native, fast, private, secure
- Your keys, your data, your choice
- Simple, instant, seamless

### Words to avoid
- Revolutionary, game-changing, cutting-edge
- AI-powered (overused)
- Subscription, monthly fee (we're BYOK)
- Cloud-first (we're privacy-first)

## Responsive Breakpoints

```css
/* Mobile first, then scale up */
@media (min-width: 640px) { /* sm */ }
@media (min-width: 768px) { /* md */ }
@media (min-width: 1024px) { /* lg */ }
@media (min-width: 1280px) { /* xl */ }
```

### Mobile considerations
- Navigation collapses to hamburger at `768px`
- Pricing grid stacks vertically on mobile
- Touch targets minimum 44x44px
- Reduce animation complexity on mobile

## Implementation Checklist

When creating new pages/materials:

1. [ ] Uses the `tokens.css` ground (#121417 dark) as base
2. [ ] Ember accent (`--accent`, #ff6b3d dark) for primary actions only
3. [ ] Cabinet Grotesk for headings, General Sans for body
4. [ ] No purple/violet gradients
5. [ ] Waveform or voice motif present
6. [ ] Scroll reveal animations on sections
7. [ ] Mobile responsive
8. [ ] BYOK/pricing transparency visible
9. [ ] Clear single CTA in hero
10. [ ] Grain texture overlay applied

## Reference Implementation

See `landing-page/index.html` and its stylesheets in `landing-page/styles/` (published together as `/site.css` by `landing-page/stylesheet.mjs`) for the canonical implementation of this design system.
