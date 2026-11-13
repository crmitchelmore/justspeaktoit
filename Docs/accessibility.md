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

### macOS, iOS and watchOS

Every control and important piece of state in the macOS, iOS, keyboard, share,
widget and watchOS targets must be usable with VoiceOver and with agents that
drive the app through the accessibility tree (computer use). Windows, Linux,
Android and the website have their own sections below.

#### Conventions

- **Names.** A control's visible text is its accessible name. When a control
  shows only an image, add `.accessibilityLabel("Verb object")` (for example
  "Remove \(word)", "Clear search"). Never rely on `.help` or a tooltip alone:
  it becomes the hint, not the name.
- **Identifiers.** Give icon-only controls, primary actions and important state
  a stable `.accessibilityIdentifier`. Use lowerCamelCase that names the
  surface and action (`historyFilterButton`), with `-\(id)` for per-row
  controls (`profileDelete-\(profile.id)`). Never put user text, secrets or
  credentials in an identifier. Keep an identifier when a view is refactored:
  UI tests and agents depend on it.
- **State.** Expose changing state as `.accessibilityValue` (a toggle-like
  icon button reads its on/off state) rather than swapping the label. The menu
  bar item is always named "Just Speak to It" and its value is the current
  state. Announce recording lifecycle changes: macOS through `HUDManager`'s
  announcement, iOS through `RecordingServiceState.accessibilityAnnouncement`,
  hands-free through its coordinator. On macOS, `HUDWindowPresenter` holds an
  announcement made while the HUD panel is hidden until the panel is on screen:
  VoiceOver drops an announcement posted just before a new window appears.
  Don't mark the HUD `.isModal`; it doesn't take focus. Mark live text and meters
  `.updatesFrequently`.
- **Toggles in agent trees.** XCUITest-based trees (agent-device, Accessibility
  Inspector's hierarchy) list a SwiftUI `Toggle` as a labelled switch with an
  unnamed `0`/`1` switch inside it: the embedded `UISwitch`. VoiceOver visits
  the toggle once, as one element with its label and value, so this is not a
  duplicate. Target the outer, labelled switch, and keep using the native
  `Toggle` rather than rebuilding it to hide the inner switch.
- **Custom controls.** Prefer `Button` over `.onTapGesture`. If a gesture is
  needed, add `.accessibilityAddTraits(.isButton)` or an
  `.accessibilityAction`. Combine row content with
  `.accessibilityElement(children: .combine)` or `.ignore` plus a label.
  Hide decorative images with `.accessibilityHidden(true)`.
- **Dismissal.** Every macOS sheet has a Cancel/Close/Done button with
  `.keyboardShortcut(.cancelAction)` (or a `.cancellationAction` toolbar item)
  so Escape closes it; confirming buttons use `.defaultAction`. UIKit modal
  controllers override `accessibilityPerformEscape()`.
- **Text size and contrast.** Use text styles (`.body`, `.headline`) or
  `preferredFont(forTextStyle:)` with `adjustsFontForContentSizeCategory`, not
  fixed point sizes, for text. Fixed sizes are acceptable only for decorative
  symbols. Use semantic colours (enforced by the `fixed_black_text` SwiftLint
  rule) and keep meaning out of colour alone.
- **Page chrome (macOS):** page headers, compact strips, chips and badges come
  from `Sources/SpeakApp/Views/PageChrome/`. `PageHeroHeader` and
  `PageHeroStrip` make every label inside them white on the palette gradient,
  and `SpeakTextStyle` holds the fonts, on-tint colours and truncation
  (`speakSingleLine`, `speakLiveTranscriptLines`) for the whole app. Change
  them there, not per page. `PageHeroContrastTests` fails if any palette stop
  or on-tint token drops below 4.5:1. SwiftLint rejects copies outside that folder:
  `hand_rolled_on_tint_text` (`.white` foregrounds), `hand_rolled_page_title`
  (`Text(…).font(.largeTitle)`) and `hand_rolled_gradient_surface`
  (`LinearGradient(`; use `.pageBackground(_:)` for page washes). The HUD is
  exempt; any other exception needs `// swiftlint:disable:next <rule>` with a
  reason.

#### Automated guard

`scripts/accessibility/check-apple-accessibility.py` runs in `make lint` (and so in the CI
Lint job) and in `make test-tooling`. It fails on:

| Rule | Meaning |
| --- | --- |
| `icon-only-control` | `Button`/`Menu`/`Link` whose label is only an `Image`, with no `.accessibilityLabel` |
| `icon-only-missing-id` | a labelled icon-only control without `.accessibilityIdentifier` |
| `empty-control-label` | `Toggle("")`, `Picker("")`, `TextField("")` and similar without `.accessibilityLabel` |
| `untitled-control` | a `Slider(value:)` or `TextEditor(text:)` with no label closure and no `.accessibilityLabel`; a caption drawn as a separate `Text` does not name the control, so VoiceOver reads only its value |
| `unlabelled-segmented-picker` | an iOS `Picker` with `.pickerStyle(.segmented)` and no `.accessibilityLabel` or `.accessibilityIdentifier`; UIKit's segmented control drops the Picker title, so the control has no name (macOS keeps it) |
| `tap-without-trait` | `.onTapGesture`/`.onLongPressGesture` without the button trait or an accessibility action |

Run it locally with `make lint-accessibility`. For a deliberate exception put
`// a11y-ignore: <reason>` on the line above the control. The check is static:
a label built by a helper property is not inspected, so review those by hand.

#### Manual verification

VoiceOver reading order, announcements and largest text sizes need a person.
Those checks live in [`manual-checks.yml`](manual-checks.yml) (served at
justspeaktoit.com/qa, issue #1399). Do not run UI automation on the owner's
Mac; UI tests run on hosted CI.

### Windows (UI Automation)

- Use standard Win32 controls. The system UI Automation proxy names a button
  from its text and a field (edit, combo box, list, hotkey) from the static
  label created immediately before it, so create the label first. Owner-drawn
  push buttons keep their window text, so their name survives.
- The control ID is the UI Automation `AutomationId`. Every focusable control
  needs a non-zero ID that is unique within its window.
- Announce with `jsti::accessibility::announce`, which raises a UI Automation
  notification that Narrator, NVDA and JAWS speak. Do not rely on
  `EVENT_SYSTEM_ALERT`. Every top-level window calls
  `jsti::accessibility::attach` on `WM_CREATE` so notifications come from its
  root provider. Narrator drops notifications from a window that is not in the
  foreground, so announce from the foreground window (the HUD does this) and
  re-announce a repeated result, such as a second failed start.
- A control with no label to its left gets its name from
  `jsti::accessibility::name`. Do not leave a list or pane unnamed.
- Keyboard focus must always land on something the user can act on. A page
  shortcut or navigation moves focus to the new page. A closed dialog or
  wizard returns focus to the control that opened it. Reactivating the window
  restores the last focused control. A read-only multi-line edit must let Tab
  and Shift+Tab move focus.
- Do not set a list's selection while the list is not focused: the proxy turns
  the selection change into a focus announcement. Tab from settings search
  closes the search, restoring the sidebar, and moves on to the next control.
- Guard: `--ui-smoke-test` runs `jsti::accessibility::audit` on every main
  window page and fails when a shown, focusable control lacks a unique
  AutomationId or a name. Its screen-reader self-test covers the root provider,
    search announcements, Tab out of search, the transcript's Tab handling and
    focus restored on activation.

### Linux (GTK 4 and AT-SPI)

- Icon-only buttons need `GTK_ACCESSIBLE_PROPERTY_LABEL`; GTK exposes the
  tooltip only as a description.
- `GtkDropDown` labels itself by its selected value, which outranks
  `GTK_ACCESSIBLE_PROPERTY_LABEL`. Name drop-downs with
  `jsti_accessible_set_name` or a mnemonic label.
- Repeated buttons (such as each local model's Download) carry the item in
  their accessible name, e.g. `Download Whisper Tiny`.
- Accessible names are the stable handles that AT-SPI agents use, so keep them
  short, unique within a window and independent of state where possible.
- The window status label has the `status` role. Announce with
  `jsti_accessible_announce`, which speaks through the widget's window: GTK
  silently drops `gtk_accessible_announce` on a child widget whose accessible
  context a screen reader has not queried yet.
- GTK does not treat the `status` role as a live region, so an idle
  status-only update (a finished model download, a saved setting) is
  announced once. A state change announces the status it carried, even if a
  later status-only update (such as a recording sound warning) replaces the
  label first.
- Making the focused Record button insensitive while transcribing moves focus
  to Cancel; when the work ends, focus returns to the Record button that was
  pressed.
- Wizard steps that rebuild a page announce the new step and put focus back on
  the button that was pressed, because making the footer insensitive drops it.
- Name read-only text views, such as the transcript (`Transcript`).
- Opening a page from the collapsed sidebar, or from a settings search result
  in either layout, moves focus into the page; focus left on the hidden sidebar
  is lost, and focus left on the search makes Orca read the wrong place. A
  Ctrl+number shortcut pressed on a sidebar row moves focus to the new row.
- Keep read-only `GtkFlowBox` grids out of the focus chain with
  `gtk_widget_set_can_focus(flow, FALSE)`. Marking each `GtkFlowBoxChild`
  unfocusable is not enough: the flow box still reports that it took focus,
  so Tab stops moving.
- A `GtkFlowBox` that lays out buttons (About links, Troubleshooting actions)
  marks each `GtkFlowBoxChild` with `gtk_widget_set_focusable(child, FALSE)`,
  so focus goes straight to the button: one Tab stop per button, not an extra
  silent "table cell" before each.
- A navigation list is one Tab stop, as GTK lists are: Tab enters on the
  selected row and leaves the list, and the arrow keys move between rows
  (`gtk_list_box_set_tab_behavior(list, GTK_LIST_TAB_ITEM)`, with a small
  focus-scope wrapper for GTK before 4.18). Otherwise Tab walks every sidebar
  row and, because selection follows focus, opens each page in turn.
- Selectable labels kept for mouse copying (About version details,
  Troubleshooting findings) are both `gtk_widget_set_focusable(label, FALSE)`
  and `gtk_widget_set_can_focus(label, FALSE)`: a selectable label's focus
  handler claims Tab even when it cannot take focus, so `focusable` alone
  traps Tab on it. A focused selectable label is read as silent or as
  "selected opens popup".
  Where the text explains a button, compose it into the button's
  `GTK_ACCESSIBLE_PROPERTY_DESCRIPTION`. Orca reads the targets of a
  described-by relation in varying order.
- Activating a control with Return or Space keeps the focus ring visible, even
  after GTK's `gtk-keyboard-focus-visible-timeout` has hidden it and the
  control keeps focus (Start Recording with no API key).
- A scrolled area with nothing focusable inside is
  `gtk_widget_set_can_focus(scroller, FALSE)`, because an empty
  `GtkScrolledWindow` takes focus itself and Orca reads an unnamed "scroll
  pane" (settings search with no match, Troubleshooting before its findings
  arrive; once they do, Troubleshooting focuses Check again if nothing has
  focus). Down from the settings search with no match stays in the entry and
  repeats "No settings match".
- Guard: `scripts/accessibility/check-linux-accessibility.py` runs in the Linux workflow and
  fails on unnamed icon buttons, on drop-downs named only by property and on
  raw `gtk_accessible_announce` calls. The window self-test checks the status
  role, that dashboard flow boxes never swallow Tab, that setup steps keep
  keyboard focus, that collapsed-sidebar and search navigation move focus into
  the page, that sidebar shortcuts move focus with the selection, that About
  links take one Tab stop each, that idle status notices and state changes are
  announced as described above and that the Record buttons hand focus to Cancel
  and back. It also checks that the wide sidebar is one Tab stop, that the
  About and Troubleshooting labels are not, that keyboard activation keeps the
  focus ring visible and that empty settings search results and an empty
  Troubleshooting window keep focus out of their scrolled areas.

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

## Manual checks

Automated guards check structure, not the listening experience. Checks that
need a real screen reader go into [`Docs/manual-checks.yml`](manual-checks.yml)
and appear at <https://justspeaktoit.com/qa>. See [manual-qa.md](manual-qa.md).
