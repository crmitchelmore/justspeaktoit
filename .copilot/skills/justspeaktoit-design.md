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
```css
:root {
  /* Backgrounds */
  --color-bg: #0b0f14;               /* Obsidian */
  --color-bg-elevated: #111a26;      /* Lifted surface */
  --color-bg-card: #1a2533;          /* Card surfaces */
  
  /* Text */
  --color-text: #f8fafc;             /* Primary text, near-white */
  --color-text-muted: #9aa6bd;       /* Secondary text, slate */
  
  /* Accent (ember + saffron) */
  --color-accent: #ff6a3d;           /* Ember */
  --color-accent-warm: #ff9b4a;      /* Saffron */
  --color-accent-deep: #e4512f;      /* Ember deep */
  --color-accent-glow: rgba(255, 106, 61, 0.32); /* For shadows/glows */
  
  /* Supporting */
  --color-secondary: #2dd4bf;        /* Lagoon teal for contrast */
  --color-success: #4ade80;          /* Green for positive states */
  --color-border: rgba(255, 255, 255, 0.08);
}
```

### Color usage rules
- **Accent (ember)**: Primary CTAs and core brand moments
- **Accent warm (saffron)**: Gradients and subtle highlights only
- **Secondary (lagoon)**: Sparse contrast—use in small doses
- **Success (green)**: Status indicators, confirmation states
- **Never**: Don't mix accent + secondary in the same element unless it is a hero gradient

### Dark mode is default
The brand is dark-mode native. Light mode should feel like an inversion, not the primary experience.

## Typography

### Font stack
```css
:root {
  /* Display/headings: Satoshi - geometric, modern, confident */
  --font-display: 'Satoshi', -apple-system, BlinkMacSystemFont, sans-serif;
  
  /* Body: General Sans - readable, friendly, professional */
  --font-body: 'General Sans', -apple-system, BlinkMacSystemFont, sans-serif;
}
```

### Font loading
```html
<link rel="preconnect" href="https://api.fontshare.com">
<link href="https://api.fontshare.com/v2/css?f[]=satoshi@700,900&f[]=general-sans@400,500,600&display=swap" rel="stylesheet">
```

### Type scale
| Element | Font | Weight | Size |
|---------|------|--------|------|
| Hero title | Satoshi | 900 | clamp(3rem, 8vw, 6rem) |
| Section title | Satoshi | 900 | clamp(2rem, 5vw, 3rem) |
| Card title | Satoshi | 700 | 1.25rem |
| Body | General Sans | 400-500 | 1rem |
| Small/muted | General Sans | 400 | 0.9rem |
| Eyebrow | General Sans | 600 | 0.85rem, uppercase, letter-spacing: 0.15em |

## Visual Elements

### The waveform motif
The animated waveform is a signature brand element representing voice/audio:
```css
.waveform-bar {
  width: 4px;
  background: linear-gradient(to top, var(--color-accent-deep), var(--color-accent-warm));
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
  background: var(--color-bg-card);
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
  background: linear-gradient(135deg, var(--color-accent) 0%, var(--color-accent-warm) 100%);
  color: var(--color-bg);
  box-shadow: 0 0 30px var(--color-accent-glow);
}

.btn--primary:hover {
  transform: translateY(-3px) scale(1.02);
  box-shadow: 0 0 50px var(--color-accent-glow);
}
```

### Badges/pills
```css
.badge {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  background: var(--color-bg-card);
  border: 1px solid rgba(255, 255, 255, 0.1);
  padding: 0.5rem 1rem;
  border-radius: 100px;
  font-size: 0.85rem;
  color: var(--color-text-muted);
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

Apply a consistent accent color across macOS + iOS:

```swift
private let brandAccent = Color(red: 1.0, green: 0.42, blue: 0.24) // Ember

ContentView()
  .tint(brandAccent)
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

1. [ ] Uses dark background (#0b0f14) as base
2. [ ] Ember accent (#ff6a3d) for primary actions only
3. [ ] Satoshi for headings, General Sans for body
4. [ ] No purple/violet gradients
5. [ ] Waveform or voice motif present
6. [ ] Scroll reveal animations on sections
7. [ ] Mobile responsive
8. [ ] BYOK/pricing transparency visible
9. [ ] Clear single CTA in hero
10. [ ] Grain texture overlay applied

## Reference Implementation

See `/landing-page/index.html` for the canonical implementation of this design system.
