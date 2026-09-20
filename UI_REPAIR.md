# UI Repair Inventory — Vamp Assistant silver migration

Actual production owners, verified causes, and repairs. Screens verified by
capture are marked; anything not captured is marked UNVERIFIED.

Reference: `tmp/instrument/02_APPROVED_COMPOSER.png` (canonical composer),
`/Users/m/Downloads/Vamp_Composer_Exact_Match_Fix/references/APPROVED_COMPOSER.png`.
Canonical fixture: `--design-preview composer` (960pt, bottom-docked).

| Screen/component | Production file | Legacy styling / defect | Replacement | Verification |
|---|---|---|---|---|
| Composer chassis | `App/InstrumentComposer.swift` `InstrumentComposer.chassis` | Old `ComposerView` card (deleted) | Ratio-driven chassis (4.28155:1), endcaps 7.71/7.86%, editor 50.8%, strip 38.8% | Captured `tmp/design-captures/canonical-composer.png`; frame 960×224.2177 |
| Left endcap controls | `InstrumentComposer.leftControlButton` | Bare glyphs (no faces) | 28pt circular silver faces, rim, top highlight, contact shadow | Captured (canonical) |
| Model/Tools/mode selectors | `InstrumentComposer.capsuleLabel` | Text-only actions | Light capsule faces w/ rim + dark inserted mode capsule; unequal module widths 20.1/15.1/22.1% | Captured (canonical) |
| Right dial | `InstrumentComposer.dial` | Missing in early builds | Raised cap 48 + barrel 54, index marker, contact shadow; bound to `SettingsStore.outputStyle` w/ menu access | Captured (canonical) |
| Indicator bank | `InstrumentComposer.indicatorBank` | Wrapped labels | Single-line fixedSize labels, truthful states | Captured (canonical) |
| Placeholder contrast | `InstrumentComposer.editorRecess` | Pale on silver | `Theme.placeholderOnSilver` semantic token | Captured (canonical, light) |
| Suggestion row | `InstrumentComposer.SuggestionRow` | White-on-light invisible | `secondaryOnSilver` label + `controlInsert` capsules w/ `textOnControlInsert` | Captured `dock2-welcome-light.png` |
| Dock placement | `ChatView.bottomDock` | Mid-screen in one fixture | Bottom-docked: maxY = workspace.maxY − 24; midX = workspace midX | Measured: delta 0.0pt, gaps 39.5/39.5, bottom 24 |
| Transcript surface | `ChatView.transcript` | Dark/black stage in light | `Theme.readingSurface` behind scroll | Captured `dock2-chat.png` (pending recapture) |
| Status row | `StatusBarView.body` | Full-width gray band | `headerSurface` + structural divider, secondary ink | Pending recapture |
| Sidebar surface | `SidebarChrome.sidebarSurface` | Pale/black hybrid | `navigationSurface` gradient | Pending recapture |
| Sidebar footer | `SidebarView.sidebarFooter` | Unrelated black strip | Opaque `Theme.bg` + `librarySurface` (same family) | Captured earlier; pending recapture |
| Collapsed chat nav | `SidebarView.ChatRail` | Hamburger-only | 64pt silver rail, 44pt slots, hover-name overlays | Captured pending |
| Settings rail | `SettingsView.SettingsRail` | — (kept) | Silver spine, hover names, focus ring | Captured `settings-general.png` |
| Settings cards | `SettingsChrome.SettingsCard` | Glass/outline mix | `instrumentFaceplate` + engraved micro-labels | Captured |
| Console | `BotConsolePanel` | Dark slab | `instrumentRecess` | UNVERIFIED (not recaptured) |
| Buttons | `Theme.LFCapsuleButtonStyle` / `LFIconButtonStyle` | Dark-glass capsules | Silver gradient keys / dark inserts | Captured across settings |
| Wallpaper | `AtmosphereBackground` | Dominant ruins photo | Removed; flat `Theme.bg` canvas | Captured all screens |
| Typography default | `SettingsStore.typeface` | Default serif caused serif UI | Default `.sans`; saved preferences preserved; composer always `.system` | Captured |

## Remaining known gaps
- Console/Network/Plugins captured this pass (`repair-settings-network.png`,
  `repair-settings-plugins.png`); visual review pending.
- Dark appearance adaptation not re-verified after token change.

## Capture evidence (light reference profile, 1320×856)
- `tmp/design-captures/canonical-composer.png` — canonical 960×224.2177 fixture.
- `tmp/design-captures/repair-chat.png` — populated production chat: light
  reading surface, dark prose, silver library + footer, quiet status row,
  docked composer with dial / black mode capsule / shaped selectors.
- `tmp/design-captures/repair-welcome.png` — welcome + suggestions above dock.
- `tmp/design-captures/repair-settings-general.png`, `repair-settings-models.png`,
  `repair-settings-bots.png`, `repair-settings-network.png`,
  `repair-settings-plugins.png`, `repair-bots.png` — migrated routes.
- `tmp/design-captures/repair-collapsed.png` — 64pt silver utility rail.
- Measured: composer midX delta 0.0pt; side gaps 39.5/39.5; bottom gap 24pt.
