# iOS / iPadOS polish — 8 September 2026

## Findings and changes

| Before | After | Reason |
| --- | --- | --- |
| Sessions hid Bots, Control Mac, and App Stream in overflow while the header lacked useful controls | The same actions are directly accessible in a header group, beside identity/status at regular width and below it on phones; accessibility sizes stack the buttons | Improve discovery and use header space |
| Composer reserved an 82pt empty editor plus layered insets | 62pt portrait editor minimum, 6pt recess inset, 8pt outer horizontal inset, 4pt top and 2pt bottom inset; compact editor stays 40pt | Reduce empty footprint without reducing the controls' 44pt targets |
| Status strip consumed a separate 26pt band | 22pt minimum strip integrated into the chassis; Steer keeps its 44pt target | Tighten the idle dock and preserve active actions |
| Pairing presented similarly weighted buttons beneath a plain explanation | Dedicated pairing module, stronger scan action, numbered Mac/device guidance, desktop glyph, and separate secondary methods | Clarify the order and role of each action |
| Pairing remained a single narrow column at larger widths | Two columns on iPad or compact-height landscape; one column at accessibility text sizes | Use width while retaining scrollable content |
| Primary disabled buttons faded all content | Recessed neutral disabled face with explicit readable foreground | Keep disabled setup actions legible in both appearances |
| Expanded approval diffs could lose Show less | Collapse remains reachable after expansion; code is selectable and uses the shared recess | Preserve review usability |

## Shared construction and feedback

- `RemoteSignal` provides a small semantic dot. Pulsing is limited to actual connection/refresh/run/sending activity; it stops when the scene is inactive and is static under Reduce Motion. Ready/connected state remains steady green; offline remains neutral.
- `RemoteInstrument.motion` uses a 0.28 response spring with critical damping. Existing shared buttons, segmented selectors, approval expansion, and session-row feedback inherit it.
- Segments use a small orange selected marker. Settings accent swatches retain their stored palette and selected checkmark, with shared press feedback and a restrained selection transition.
- Manual pairing expansion uses the shared motion preset. Native sheet/navigation transitions continue to own presentation. No whole-composer focus animation was introduced.
- Settings and new-session navigation rows use shared press feedback; new-session icons have a stable alignment column. Bots use the shared activity dot for actual nonterminal runs.
- Silver/light and graphite/dark surfaces continue to use adaptive tokens. Green, orange, and danger colors retain their semantic meanings. Saved accent choice is unchanged.

## Preserved behavior

Existing sheet destinations, model selection, tools, share, Chat/Run flows, reconnect, scan, manual pairing, Tailscale, permissions, approvals, send/queue/steer/stop, and long-text input limits remain in place. Transcript rendering, long-answer layout, and scrolling logic retain the prior refinement. No release file or installed application is replaced by this source pass.

## Verification and remaining edges

- Final arm64 device Release build succeeded: `/tmp/vamp-final-polish-release.log`.
- Whitespace validation passed for the iOS source.
- The broad regression run crashed with `NSGenericException: Task created in a session that has been invalidated` from the event-stream task during concurrency testing. This also occurred before this pass. Log: `/tmp/vamp-final-polish-tests.log`. It is not a passing suite and its underlying lifecycle issue remains unresolved.
- Focused protocol/persistence suite passed all 13 tests, zero failures: `/tmp/vamp-final-polish-focused-tests.log`.
- No new screenshots were generated, respecting the user's earlier request. Layout and motion changes have build verification but have not received a new visual or interactive device review. Physical-device keyboard/rotation behavior, VoiceOver traversal, live pairing/approval round trips, and the background-stream lifecycle issue remain release checks.
- The previously delivered IPA 0.1.39 (93) predates these edits; this pass does not change its bytes.
