# Accessibility and computer use

Every control and every important piece of state must be reachable and
understandable through the platform accessibility tree. That one tree serves
screen readers (VoiceOver, Narrator, NVDA, Orca, TalkBack) and agents that
drive apps through accessibility APIs (computer use, UiAutomator, AT-SPI and
UI Automation clients). A control that a screen reader can name and operate is
one an agent can find and press.

## Shared rules

1. **Names.** Every focusable control has an accessible name that says what it
   does. Icon-only controls always get an explicit label; a tooltip is not a
   name.
2. **Roles, values and states.** Prefer standard platform controls, which
   expose role, value and state for free. A custom control declares its role
   (button, switch, status) and updates its label or state when it changes, for
   example Record becoming Stop.
3. **Stable automation IDs.** Controls that agents drive have an identifier that
   does not change with language or wording. Never reuse or rename a published
   ID; add a new one instead.
4. **Announcements.** Recording, transcribing, completion and failure are
   announced without moving focus, through the platform live-region or
   notification mechanism. Announce state changes once: the HUD announces when
   it is shown, and the main window announces only when the HUD is hidden.
5. **Keyboard.** Everything works from the keyboard with visible focus, a
   logical tab order and Escape to dismiss dialogs.
6. **Contrast.** Text meets WCAG 2.2 AA (4.5:1) in light and dark appearances.
7. **Decorative content** is hidden from the tree rather than given a
   meaningless label.

## Platforms

### Windows (UI Automation)

- Use standard Win32 controls. The system UI Automation proxy names a button
  from its text and a field (edit, combo box, list, hotkey) from the static
  label created immediately before it, so create the label first. Owner-drawn
  push buttons keep their window text, so their name survives.
- The control ID is the UI Automation `AutomationId`. Every focusable control
  needs a non-zero ID that is unique within its window.
- Announce with `jsti::accessibility::announce`, which raises a UI Automation
  notification that Narrator, NVDA and JAWS speak. Do not rely on
  `EVENT_SYSTEM_ALERT`.
- Guard: `--ui-smoke-test` runs `jsti::accessibility::audit` on every main
  window page and fails when a shown, focusable control lacks a unique
  AutomationId or a name.

### Linux (GTK 4 and AT-SPI)

- Icon-only buttons need `GTK_ACCESSIBLE_PROPERTY_LABEL`; GTK exposes the
  tooltip only as a description.
- Accessible names are the stable handles that AT-SPI agents use, so keep them
  short, unique within a window and independent of state where possible.
- The window status label has the `status` role. Announce with
  `gtk_accessible_announce`.
- Guard: `scripts/check-linux-accessibility.py` runs in the Linux workflow and
  fails on unnamed icon buttons. The window self-test checks the status role.

### Android (TalkBack and accessibility services)

- Compose: every `Icon` or `Image` has a `contentDescription`. Pass `null`
  only for decorative images, with a `// Decorative:` comment on the line
  before saying where the label lives. Custom clickables declare
  `role` and `contentDescription` in `semantics`.
- Status text uses `liveRegion = LiveRegionMode.Polite`.
- Stable IDs live in `ui/AutomationIds.kt` and are applied with
  `Modifier.testTag`. `MainActivity` sets `testTagsAsResourceId`, so they
  appear as `resource-id` to UiAutomator and accessibility services.
- Views built in code, such as the dictation keyboard, get IDs from
  `res/values/ids.xml`.
- Guards: `AccessibilitySourceTest` (unit test) and the accessibility lint
  checks configured as errors in `app/build.gradle.kts`.

### Website (justspeaktoit.com)

- Each page has `lang`, a title, one `main` landmark, one `h1`, a skip link,
  unique `id`s, named links, buttons and images, labelled form controls and a
  visible `:focus-visible` outline. Never disable zoom.
- Dynamic status uses `role="status"` or `aria-live`. Element `id`s are the
  stable selectors for automation; add `data-testid` only where no `id` fits.
- Respect `prefers-reduced-motion` and `prefers-color-scheme`.
- Guard: `landing-page/accessibility.test.js` runs with `npm test` in the
  website workflow, including AA contrast for every text token on every page
  background in both schemes.

### macOS, iOS and watchOS

Covered by the Apple accessibility work; add platform rules here.

## Manual checks

Automated guards check structure, not the listening experience. Checks that
need a real screen reader go into [`Docs/manual-checks.yml`](manual-checks.yml)
and appear at <https://justspeaktoit.com/qa>. See [manual-qa.md](manual-qa.md).
