# Vamp iOS — compact composer and tactile controls

Implemented design: silver in light mode, neutral graphite in dark mode, open conversation typography, and shallow physical controls. This supersedes the earlier instructions to reserve a large editor, show dark user cards, and keep a permanent composer status strip.

## Audit and implementation

| Priority | Before | Implemented |
| --- | --- | --- |
| Critical | Empty editor could expand to its 176pt maximum, above controls and status | Intrinsic one-line editor; approximately 98pt complete empty composer at standard text size. Six lines in portrait, three in landscape, then native internal scrolling. |
| Critical | Dark trailing user bubble with reduced reading width | User and assistant turns share the same open column, 16pt phone gutters and 24pt turn spacing. No user bubble, fill, border, or trailing alignment. |
| High | Streaming answer started 41pt farther right | Streaming and completed answers use the same `RemoteTranscriptTurn` layout. |
| High | Buttons scaled and faded; several independent styles | Shared key surface with stationary housing, 1pt depression, collapsing face shadow, inset shading, and 80ms/140ms press/release timing. Shadows affect the face, not text. |
| High | Offline conversation header still said READY | Header resolves Offline, Error, Sending, active phase, and Ready. Composer status strip removed. |
| High | Permanent model, tools, mode, keyboard and action bays consumed space | Plus, flexible model selector, tools, primary action. Mode appears in the model sheet. Keyboard dismissal appears in navigation only while the keyboard is visible. |
| High | Some terminal/remote-control keys were smaller than 44pt | 44pt keys, common selected/pressed surfaces; narrow remote toolbars scroll horizontally. |
| Medium | Tool results appeared as permanent cards with truncated details | Quiet disclosure rows, expandable and selectable full technical output. Reasoning has an inset background only when expanded. |
| Medium | Accent keys squeezed to fit one row | Adaptive grid preserves minimum 44pt targets. Settings row labels use normal body case. |
| Medium | Pairing repeated its introduction | One headline, brief purpose statement, numbered setup instructions, prominent scanning action and secondary recovery options. |

The shared form spacing and key surfaces flow through sessions, bots, pairing, settings, model selection, sharing, approvals, and control panels. Existing navigation, remote input handling, network protocol, persistence, draft storage, and approval handlers are retained.

Accessibility text sizes use a lower editor line cap (three portrait, one compact-height), a wrapping two-line model label, and stacked portrait actions. The full model name remains in its accessibility label. Increased Contrast strengthens key edges; Reduce Motion removes key travel while retaining tonal state changes. Disabled and selected states are distinct. Existing user accent preferences remain respected.

## Native design previews

Xcode previews named **Silver composer** and **Graphite composer** use the production composer and transcript components. The DEBUG launch fixture `VAMP_REMOTE_TEST_SCREEN=composer` includes editable text, Ready/Running/Offline/Sending states, live press and selection samples, and observable Send/Queue/Steer/Stop outcomes. `VAMP_REMOTE_FIXTURE=multiline` seeds an overflowing draft. These fixtures do not restore a real Mac connection.

`RemoteKeyStatePreview` renders resting, pressed, selected, disabled and busy surfaces through the same production modifier.

## Evidence

Artifacts are in `/Users/m/Downloads/beetcode/tmp/ios-tactile-polish/`:

- `before/`: 60 fresh light/dark production captures made from the pre-change binary.
- `after/`: matching final iPhone production captures.
- `ipad/`: iPad production and split-layout captures.
- `interaction/`: actual simulator keyboard, multiline, running and offline captures.
- `diff-delivery/`: Argent pixel comparison of the before/after chat. Pixel changes establish visual difference, not correctness by themselves.
- `source-before/`: backups of the seven central UI files before this implementation, preserving the user's pre-existing edits.

Production chat captures use an isolated offline session, so disabled model/share controls and the reconnect banner are intentional. Native preview captures show enabled controls. Window-rendered fixtures exclude system status chrome; interaction captures include the actual keyboard and device chrome.

## Verification

Completed checks:

- macOS baseline: 962 tests, 10 skipped, zero failures.
- iOS protocol, draft and concurrency regression suite: 28 tests, zero failures, including the previously crashing test.
- Native composer UI acceptance: five tests, zero failures.
- Production iPhone surface matrix: passed, 40 final light/dark captures.
- Production iPad surface and intrinsic-sizing checks: passed, two tests and 46 final captures.
- Intrinsic-sizing assertions: 90–100pt complete empty composer at 320/402/740pt widths, unchanged for short text; six-line portrait cap and smaller landscape cap.
- Unsigned generic iOS Release: build succeeded; arm64 executable verified. The delivery build also passed before the subsequent button refinement.
- `git diff --check` on the iOS implementation and tests: clean.

Detailed test bundles: `/tmp/vamp-regression-final.xcresult`, `/tmp/vamp-ui-acceptance.xcresult`, `/tmp/vamp-production-delivery.xcresult`, `/tmp/vamp-ipad-delivery.xcresult`, and `/tmp/vamp-states-delivery.xcresult`. Verification covers composer geometry at 320/402/740pt, focus stability, the line cap, Send/Queue/Steer/Stop routing, offline draft retention across rotation, deletion shrinkage, canceled presses, keyboard dismissal, and light/dark/large-text production layouts.

The first full iOS baseline crashed in the existing `testOldMacMutationFailuresDoNotAlertOnNewMac` test with “Task created in a session that has been invalidated.” The unchanged test subsequently passed in the isolated regression suite. A mixed rendering batch also produced blank temporary-window captures; those are kept in `after-initial/` for diagnosis and are not delivery evidence. Production rendering was rerun in isolated runs. UIKit appearance-transition and scroll-geometry diagnostics from the window fixture harness are retained in test logs.

Physical-device haptic feel, spoken VoiceOver traversal, hardware-keyboard Command–Return, CJK marked-text composition, and live Mac streaming/approval round trips still require device/session verification. Native text editing and the existing streaming follow logic remain in use; no claim is made that those manual scenarios were completed. No app publication or installation on a physical device was performed.

## Review the finished design

- [Light production chat](../../tmp/ios-tactile-polish/after/iphone-01-chat-light-fixture.png)
- [Dark production chat](../../tmp/ios-tactile-polish/after/iphone-01-chat-dark-fixture.png)
- [Real keyboard with a long draft](../../tmp/ios-tactile-polish/interaction/composer-multiline-keyboard-light.png)
- [Running, Queue and Steer](../../tmp/ios-tactile-polish/interaction/composer-running-dark.png)
- [iPad reduced-width layout](../../tmp/ios-tactile-polish/ipad/ipad-24-reduced-width-light-fixture.png)

These are rendered native SwiftUI screens, not image-generated approximations.

## Button refinement after visual feedback

The first rounded treatment was rejected as weaker than the previous controls. The revision restores matte faces and precise directional edges: no bright perimeter outline, no blurred drop shadow, a fine dark seam, a half-point top highlight and a shallow one-point lower edge. Touch-down travel and distinct selected states remain. Revised captures are in `keys-refined/`; earlier `after/` captures document the preceding button treatment.

Refinement validation: two native rendering/geometry tests passed, with 12 light/dark, small-width, split-width, accessibility and Increased Contrast captures.

- [Revised light composer](../../tmp/ios-tactile-polish/keys-refined/iphone-composer-design-light-fixture.png)
- [Revised dark key states](../../tmp/ios-tactile-polish/keys-refined/iphone-keycap-states-dark-fixture.png)

The refined button implementation also passed the unsigned iOS Release build (`/tmp/vamp-keys-release.log`).
