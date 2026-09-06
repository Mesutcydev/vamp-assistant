# Vamp Assistant for iOS — how the client is built

The iOS companion is deliberately **not** a second design system. Structure and
controls are UIKit's; three things are ours. This document is the contract for
anyone adding a screen.

## What the platform owns

Screens are `List(.insetGrouped)` or `Form` inside a `NavigationStack`, with
large titles where the screen is a destination and inline titles where it is a
sheet. Rows are standard rows with standard accessories: disclosure chevron,
trailing detail text, `Toggle`, checkmark. Buttons are `.borderedProminent`,
`.bordered`, or plain. Colours are the system's (`secondarySystemGroupedBackground`,
`.secondary`, `.green`, `.orange`, `.red`), and type is the system ramp
(`.headline`, `.body`, `.subheadline`, `.footnote`, `.caption`).

This is not aesthetic preference. It is where Dynamic Type, Increase Contrast,
Reduce Transparency, Reduce Motion, VoiceOver ordering and swipe actions come
from. Before the conversion the client had five button styles that disagreed on
press feedback and only one of which honoured Reduce Motion, eleven translucent
surfaces that ignored Reduce Transparency, and five hand-drawn selectable rows
of which three never told VoiceOver they were selected.

**Do not** introduce a house radius, spacing or type scale. There is no
`RemoteRadius`. If a value feels like it needs one, the answer is a standard
row.

## What is ours

1. **The accent.** `AccentPalette`, shared with the Mac client, defaulting to
   `beetRed` per `BRAND-KIT.md` §2. Used for tint and for the few glyphs that
   carry identity — nothing else.
2. **The backdrop.** `RemoteBackdrop` draws the engraved `WindowAtmosphere`
   behind every screen, and Settings can turn it off. Because a stock grouped
   list paints opaque cells that would hide it, rows go through
   `remoteListRow()`, which thins the system cell colour — **0.97 in light,
   0.88 in dark**, and fully opaque under Reduce Transparency. The two alphas
   are not a compromise: the engraving is dark lines on pale paper, so light
   mode needs a nearly opaque cell or text ends up sitting on texture.
3. **The agent transcript.** The one surface with no platform equivalent. It
   follows Cursor and Codex rather than a messaging app — see below.

## The shared pieces

All in `iOSApp/RemoteViews.swift`:

| Component | For |
|---|---|
| `remoteListRow()` | Every grouped row, so the backdrop reads through |
| `RemotePageHero` | A screen's own opening: glyph, name, one line of purpose |
| `RemoteDisclosureRow` | Label, optional glyph, current value, chevron — the accessory SwiftUI only draws for a push |
| `RemoteSelectionRow` | Title, subtitle, trailing checkmark, always `.isSelected` |
| `RemoteOfflineRow` | The Mac is unreachable, with a retry |
| `RemoteStageTheme` | The dark-only stage surfaces (below) |

**Every screen gets its own `RemotePageHero`.** Four sheets that all opened on a
grouped card under a one-word header read as the same page four times. The hero
is what makes them distinct without inventing a per-screen visual language.

## The transcript

An agent turn is a run, not a chat: **thinking** collapses behind a hairline
rule; **tool calls** are ledger rows — status glyph, tool name in mono, output
behind a disclosure; the **prompt** sits in a container and the **answer** does
not, which is the speaker cue. No avatars, no bubbles. Machine-emitted text is
always monospaced; counts and timings are `.monospacedDigit()`.

**Stop belongs to the run**, on the run bar above the composer — not in the
composer and not in the status strip. It exists in exactly one place.

## The dark-only surfaces

Control (screen mirroring), the terminal and the keyboard overlay stay dark in
every appearance. They frame a video feed and a terminal, and light chrome
around either is glare. They use `RemoteStageTheme`, not `BeetTheme`, and they
are the one place fixed point sizes are acceptable — key caps and terminal
glyphs do not reflow. Everywhere else, use the type ramp.

## Adding a screen

1. `List`/`Form` + `.scrollContentBackground(.hidden)` + `.background { RemoteBackdrop() }`.
2. `.remoteListRow()` on each section.
3. A `RemotePageHero` saying what the screen is for, in its own words.
4. A `RemoteOfflineRow` if any control on it needs the Mac.
5. Standard rows and buttons. If you are reaching for a `RoundedRectangle`,
   stop and ask what row you actually want.

## Verification

`xcodegen generate` after adding or removing a file, then the iOS scheme's
tests, then the four settings that break hand-drawn UI: **Dark / Light /
System**, **Reduce Transparency**, **Reduce Motion**, and **Dynamic Type at
xxxLarge**.
