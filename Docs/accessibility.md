# Accessibility (Apple apps)

Every control and important piece of state in the macOS, iOS, keyboard, share,
widget and watchOS targets must be usable with VoiceOver and with agents that
drive the app through the accessibility tree (computer use). Windows, Linux,
Android and the website have their own guidance.

## Conventions

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
  hands-free through its coordinator. Mark live text and meters
  `.updatesFrequently`.
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

## Automated guard

`scripts/check-apple-accessibility.py` runs in `make lint` (and so in the CI
Lint job) and in `make test-tooling`. It fails on:

| Rule | Meaning |
| --- | --- |
| `icon-only-control` | `Button`/`Menu`/`Link` whose label is only an `Image`, with no `.accessibilityLabel` |
| `icon-only-missing-id` | a labelled icon-only control without `.accessibilityIdentifier` |
| `empty-control-label` | `Toggle("")`, `Picker("")`, `TextField("")` and similar without `.accessibilityLabel` |
| `tap-without-trait` | `.onTapGesture`/`.onLongPressGesture` without the button trait or an accessibility action |

Run it locally with `make lint-accessibility`. For a deliberate exception put
`// a11y-ignore: <reason>` on the line above the control. The check is static:
a label built by a helper property is not inspected, so review those by hand.

## Manual verification

VoiceOver reading order, announcements and largest text sizes need a person.
Those checks live in [`manual-checks.yml`](manual-checks.yml) (served at
justspeaktoit.com/qa, issue #1399). Do not run UI automation on the owner's
Mac; UI tests run on hosted CI.
