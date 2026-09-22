import AppKit
import SwiftUI

// MARK: - INSTRUMENT 01: the approved pearl composer
//
// Reference: tmp/instrument/02_APPROVED_COMPOSER.png (1024 × 252 px).
// Documented pixel→point mapping: the chassis occupies ~1008 × 240 px of the
// crop (≈8px margins). The canonical desktop scale is 1080pt wide, so
// scale = 1080 / 1008 ≈ 1.071 pt/px, giving a chassis ≈ 1080 × 257pt; the
// brief's proposed 253pt height is used as the canonical chassis height and
// the original fixture establishes the material and right-endcap language.
// Production now shares a fixed 64pt left spine with navigation; the isolated
// fixture embeds the same hardware component. Controls use 44pt hit targets.
//
//   editor recess     = upper band, ~50% chassis height
//   lower faceplate   = lower ~39% chassis height
//   dial diameter     = ~17% chassis height            (≈44pt)
//   fasteners         = ~1.6% chassis height           (≈4pt)
//
// Every control is a real interactive view bound to production state
// (ComposerStore, AgentSessionController, AppState, SettingsStore). The
// reference image is never drawn as the interface.

enum Instrument {
    /// Test-only frame reporting for the visual acceptance checks. Enabled
    /// by `--design-preview`; the composer writes its global chassis frame
    /// to a temp file so measurement scripts can verify centering and the
    /// bottom gap without debug overlays in production.
    @MainActor static var debugFrameReport = false

    @MainActor static func reportFrame(_ frame: CGRect) {
        guard debugFrameReport else { return }
        let line = "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)\n"
        try? line.write(toFile: "/tmp/vamp-composer-frame.txt",
                        atomically: true, encoding: .utf8)
    }

    /// Approved chassis aspect (visible body, shadow excluded): 4.28155:1.
    static let referenceRatio: CGFloat = 4.281553398058253
    /// Canonical one-line height at a given width.
    static func canonicalHeight(for width: CGFloat) -> CGFloat {
        width / referenceRatio
    }

    /// Canonical chassis width at desktop scale.
    static let canonicalWidth: CGFloat = 1080
    /// Chassis height at canonical width (4.27:1 from the approved image).
    static let canonicalHeight: CGFloat = 253

    static var endcapFraction: CGFloat { 0.08 }
    static var faceplateFraction: CGFloat { 0.39 }

    // Designed card material: a raised face that steps top-to-bottom and
    // carries a real edge, instead of three identical window colours. The
    // names survive because the app's controls are built from them.
    static var silverTop: Color { Theme.sectionSurfaceTop }
    static var silverMid: Color { Theme.sectionSurface }
    static var silverLow: Color { Theme.sectionSurfaceBottom }
    static var faceplate: Color { Theme.sectionSurface }
    static let silverEdgeDark = Theme.sectionStrokeStrong
    static let recessFill = Theme.wellSurface
    /// The bright edge of raised controls, paired with their body material.
    static let controlHighlight = Color(nsColor: .separatorColor)

    // MARK: Keycap material
    //
    // A moulded cap's face is nearly flat — roughly 15 points of luminance, not
    // the 35 the old controlHighlight→recessFill ramp spent. The edges do the
    // physical work (see `instrumentKey`), so these stay deliberately quiet.
    // A cap must read as a separate, lighter part sitting ON the deck. These
    // used to land within ~10 points of the chassis gradient itself, which is
    // why every control looked printed on rather than mounted in.
    // A "moulded cap" is now a plain system control face: one fill, a system
    // separator for its edge, and the pressed state AppKit already defines.
    static let keyTop = Color(nsColor: .controlColor)
    static let keyBottom = Color(nsColor: .controlColor)
    static let keyTopPressed = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let keyBottomPressed = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let keyLip = Color.clear
    static let keyWall = Color(nsColor: .separatorColor)

    // MARK: Encoder
    /// Warm off-white knob body — the same moulding family as the rail's keys.
    static let knobFace = Color(nsColor: .controlColor)
    static let knobIndex = Color(nsColor: .labelColor)
    static let trackIdle = Color(nsColor: .separatorColor)
    /// A non-adjustable level still shows its position, just not in the
    /// functional accent — an orange arc on a control you cannot turn is a lie.
    static let trackFixed = Color(nsColor: .tertiaryLabelColor)

    // MARK: Piano-action key
    //
    // The lower faceplate's named controls are a keybed: an ivory top face you
    // press, and below it the key's own FRONT LIP — the vertical face you see
    // looking down a row of piano keys. The lip is what gives a key thickness;
    // without it a control is a rectangle with a gradient in it.
    // The piano-key lip and socket drew thickness onto flat controls. Native
    // controls carry their own depth, so these collapse to a separator or to
    // nothing at all.
    static let pianoLipTop = Color.clear
    static let pianoLipBottom = Color.clear
    static let darkPianoLipTop = Color.clear
    static let darkPianoLipBottom = Color.clear
    static let keyRim = Color(nsColor: .separatorColor)
    static let keySocket = Color.clear
    /// Emphasised caps (Send, the assistant capsule) take the system accent.
    static let darkKeyTop = Color(nsColor: .controlAccentColor)
    static let darkKeyBottom = Color(nsColor: .controlAccentColor)
    static let darkKeyTopPressed = Color(nsColor: .controlAccentColor).opacity(0.8)
    static let darkKeyBottomPressed = Color(nsColor: .controlAccentColor).opacity(0.8)

    static let seam = Color(nsColor: .separatorColor)
    static let seamLight = Color(nsColor: .separatorColor)
    static let engraved = Color(nsColor: .secondaryLabelColor)
    static let darkInsert = Color(nsColor: .controlAccentColor)
    static let sendFace = Color(nsColor: .controlAccentColor)
    static let accentOrange = Color(red: 0.88, green: 0.48, blue: 0.18)
    static let signalGreen = Color(red: 0.34, green: 0.76, blue: 0.37)
    static let signalIdle = Color(red: 0.55, green: 0.55, blue: 0.55)
    /// Dark screen inserts — the display family shared by the user's message
    /// screen, the status readout, and the rail's perforated module.
    static let screenFaceTop = Color(nsColor: .textBackgroundColor)
    static let screenFaceLow = Color(nsColor: .textBackgroundColor)
    /// Primary/secondary ink for text on silver surfaces.
    static let ink = Theme.textOnSilver
    static let inkSecondary = Theme.secondaryOnSilver
    static let signalBlue = Color.fixed(0x58A4D2)
    static let signalPurple = Color.fixed(0xB77ACE)

    /// Micro-label style: spaced uppercase technical text.
    static func microLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(engraved)
    }

    /// Panel legend, ENGRAVED rather than printed: a dark cut with a lit lower
    /// lip. Flat gray text floating over a faceplate is what made the bay
    /// annotations read as UI labels instead of marks in the material.
    static func engravedLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(1.6)
            .foregroundStyle(engraved)
            .shadow(color: keyLip.opacity(0.7), radius: 0, y: 0.5)
    }

    // MARK: Compact control-strip metrics
    //
    // One deliberate spacing scale for the lower faceplate: the strip reads as
    // one precision instrument panel, so controls size to their content and
    // every gap comes from this table — never from a flexible frame.
    enum Control {
        /// Square keys in the action bank. Sized so the bank's three segments plus
        /// its hairlines read as one housing.
        static let face: CGFloat = 34
        /// Raised circular cap at the end of the rail; same family as Send.
        static let micFace: CGFloat = 36
        /// The single tallest face, used by the labelled capsules.
        static let primaryFace: CGFloat = 36
        /// Primary action inside the input. Same diameter as Mic — they differ in
        /// treatment (dark primary vs light secondary), not in size.
        static let sendFace: CGFloat = 36
        static let capsuleHPadding: CGFloat = 12
        static let capsuleLabelSpacing: CGFloat = 5
        /// Air between a cell's machined channel and the control inside it.
        static let cellHPadding: CGFloat = 11
        /// One silhouette for every face in the control row. A capsule beside a
        /// rounded rectangle beside a circle reads as three button families
        /// borrowed from three products.
        static let faceRadius: CGFloat = 6
        /// Glyphs for the bank and the circular caps.
        static let utilityIcon: CGFloat = 14
        static let micIcon: CGFloat = 15
        static let sendIcon: CGFloat = 15
        static let capsuleIcon: CGFloat = 8
        static let capsuleText: CGFloat = 13
        /// The action bank is one segmented housing, so its keys share a hairline
        /// rather than a gap.
        static let utilityGap: CGFloat = 0
        /// Between major groups (MODEL, TOOLS, ASSISTANT, ACTIONS, MIC).
        static let groupSpacing: CGFloat = 12
        /// Tighter step for controls that belong together.
        static let compactSpacing: CGFloat = 8
        /// Around a 1px seam: the divider must read as structure, not a gap.
        static let dividerSpacing: CGFloat = 10
        /// The separator itself. Centred in the control row, so it is a divider
        /// between groups and never a full-height rule.
        static let dividerHeight: CGFloat = 22
        /// Below the width where one row can hold every face without clipping.
        static let singleRowMinimumWidth: CGFloat = 600
        /// Vertical budget, stated as the equation it is:
        ///   groove 2 + input→label air 8 + annotation 10 + gap 4
        ///   + control row 44 + bottom breathing 6 = 74
        /// The 8pt of air is what keeps the MODEL/TOOLS/ASSISTANT annotations
        /// clear of the input border. Do not shrink this without re-checking it.
        /// Vertical budget, stated as the equation it is:
        ///   groove 2 + annotation clearance 6 + annotation 10 + gap 4
        ///   + control row 44 + bottom breathing 4 = 70
        static let stripSingleRowHeight: CGFloat = 70
        /// Wrapped rows: compact label band over the faces, then the second row.
        static let stripWrappedHeight: CGFloat = 112
        /// Micro-label band: 8.5pt type plus a 4pt gap to the faces.
        static let labelBandHeight: CGFloat = 14
        /// The annotation band. Fixed for every labelled bay, so the control
        /// beneath it starts at the same Y in all of them.
        static let annotationHeight: CGFloat = 10
        static let annotationGap: CGFloat = 4
        /// Air between the writing recess and the annotation text. This is the
        /// gap that stops MODEL/TOOLS/ASSISTANT colliding with the input border;
        /// without it the labels relied on the deck groove and overlapped the
        /// recess edge. Part of the strip's vertical equation, not a leftover.
        static let annotationClearance: CGFloat = 6
        /// The strip's control row. Every face is centred inside it, which is
        /// what puts every control on one centreline regardless of face size.
        /// 36pt controls get (44-36)/2 = 4pt above and below; the 34pt bank gets
        /// 5pt; the 22pt separator gets 11pt. No control is top-aligned.
        static let controlBreathing: CGFloat = 8
        static var controlRowHeight: CGFloat {
            max(primaryFace, face, micFace) + controlBreathing
        }
        /// The model identity: a real bay with a preferred width, never stretched.
        static let modelPreferredWidth: CGFloat = 160
        static let modelMaxWidth: CGFloat = 172
        static let modelLabelMaxWidth: CGFloat = 118
        /// The Tools pill.
        static let toolsPreferredWidth: CGFloat = 96
        /// The Goal capsule. Dark contrast carries its hierarchy, not size.
        static let goalPreferredWidth: CGFloat = 120
        /// The model pill shares the row's one silhouette. It used to carry a
        /// softer radius of its own, which made the widest face on the deck the
        /// one that matched nothing beside it.
        static let modelRadius: CGFloat = faceRadius
    }

    // MARK: App-wide primitive tokens
    //
    // Small, predictable scales the composer builds on. `Radius` already covers
    // corner geometry app-wide, so these add only what was missing.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    enum ControlSize {
        static let compact: CGFloat = 28
        static let small: CGFloat = 32
        static let regular: CGFloat = 34
        static let medium: CGFloat = 36
        static let large: CGFloat = 40
    }

    enum IconSize {
        static let micro: CGFloat = 10
        static let small: CGFloat = 12
        static let regular: CGFloat = 14
        static let medium: CGFloat = 16
        static let large: CGFloat = 18
    }

    // MARK: Adaptive writing recess
    //
    // The composer is a bottom-anchored object: the recess is the only region
    // that grows, and only because real content arrived.
    /// Empty and unattached: a compact, low-profile input, not a canvas. Holds
    /// one wrapped line of real text plus the 40pt send face and its inset, so
    /// the action never leaves the box and the box never looks half empty.
    static let minimumEditorHeight: CGFloat = 64
    /// Where growth stops and the editor scrolls internally instead.
    static let maximumEditorHeight: CGFloat = 216
}

// MARK: - Composer

struct ComposerDockHeightKey: PreferenceKey {
    /// Fallback reservation for the rail's hardware spine before the composer
    /// has reported its real docked height.
    static let defaultValue: CGFloat = 290
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct InstrumentPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10),
                       value: configuration.isPressed)
    }
}

// MARK: - Suggestion row

struct SuggestionRow: View {
    var store: ComposerStore
    var availableWidth: CGFloat
    @State private var rotation = 0

    init(store: ComposerStore, availableWidth: CGFloat = 1000) {
        self.store = store
        self.availableWidth = availableWidth
    }

    private struct Suggestion: Identifiable {
        var id: String { text }
        let marker: Color
        let text: String
        let draft: String
    }

    private var suggestions: [Suggestion] {
        let all: [Suggestion] = [
            .init(marker: Instrument.signalGreen, text: "Summarize this page", draft: "Summarize the current page."),
            .init(marker: Instrument.signalBlue, text: "Write a doc", draft: "Draft a document about "),
            .init(marker: Instrument.accentOrange, text: "Search the web", draft: "Search the web for "),
            .init(marker: Instrument.signalPurple, text: "Open a project", draft: ""),
            .init(marker: Instrument.signalIdle, text: "Analyze files", draft: "Analyze the files in "),
        ]
        let r = rotation % all.count
        return Array(all[r...] + all[..<r])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try something")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            HStack(spacing: 10) {
                ForEach(suggestions.prefix(max(1, min(5, Int((availableWidth - 100) / 190))))) { suggestion in
                    Button {
                        select(suggestion)
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(suggestion.marker).frame(width: 6, height: 6)
                                .accessibilityHidden(true)
                            Text(suggestion.text)
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel(suggestion.text)
                }
                Button { rotation += 1 } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Refresh suggestions")
                .accessibilityLabel("Refresh suggestions")
            }
        }
    }

    private func select(_ suggestion: Suggestion) {
        if suggestion.text == "Open a project" {
            NotificationCenter.default.post(name: .openWorkspace, object: nil)
            return
        }
        store.prompt = suggestion.draft
    }
}

struct InstrumentLiveSignal: View {
    let active: Bool
    var bars = false
    var tint: Color = Instrument.signalGreen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let animates = active && !reduceMotion && scenePhase == .active
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animates)) { context in
            let time = animates ? context.date.timeIntervalSinceReferenceDate : 0
            let breath = animates ? (sin(time * 2.1) + 1) / 2 : 1
            let color = active ? tint : Instrument.signalIdle
            if bars {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4) { index in
                        Capsule()
                            .fill(color.opacity(active ? 0.8 : 0.5))
                            .frame(width: 2, height: animates
                                   ? 4 + 7 * (sin(time * 2.4 + Double(index) * 0.9) + 1) / 2
                                   : 5)
                    }
                }
                .frame(width: 14, height: 12)
            } else {
                Circle()
                    .fill(color)
                    .opacity(active ? 0.6 + 0.4 * breath : 1)
                    .shadow(color: color.opacity(active ? 0.3 * breath : 0), radius: 3)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// TE vertical reasoning fader: a machined slot cut into the frame with an
/// engraved tick ladder, a lit accent column showing the current level, and a
/// moulded cap that rides to the top for the highest level. Not a generic
/// slider — the same construction as every key on the deck.
///
/// Positions read bottom → top: AUTO at the bottom, then each advertised
/// reasoning effort. Dragging the cap snaps between stops.
