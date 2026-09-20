import SwiftUI

// MARK: - TE control rail
//
// The lower composer rail is one continuous instrument panel with keys cut into
// it — the OP-1 Field / TX-6 language: matte surfaces, 1px seams, almost-square
// geometry, tiny engraved legends over high-contrast values.
//
// The rule that drives the whole system: THE KEY IS THE CONTROL. A legend and
// its value live INSIDE one pressable face. The previous rail put a legend and
// a rounded button inside a bordered section, which read as a box inside a box
// — a macOS toolbar, not a hardware surface.
//
// Geometry is owned by `TEKeyGroup`, never by the individual key. The group
// clips, outlines and seams its children, so adjacent keys can never produce a
// doubled border or a mismatched radius.

/// One dimension system for every face on the rail. Nothing down here sizes
/// itself; a control that needs different proportions changes a token.
enum TE {
    static let railHeight: CGFloat = 68
    /// Key body height. Label row + value row + the key's own vertical inset.
    /// Sized so the keybed fits the 46pt frame deck with equal breathing room.
    static let keyHeight: CGFloat = 34
    static let keyRadius: CGFloat = 4
    static let seam: CGFloat = 1
    static let horizontalInset: CGFloat = 8
    static let groupSpacing: CGFloat = 14

    // Shared baseline grid. Every key reserves the same two rows, so the
    // legends line up across the rail and so do the values — including on keys
    // that carry only a glyph.
    static let labelRow: CGFloat = 9
    static let labelToValue: CGFloat = 4
    static let valueRow: CGFloat = 17
    static let keyVPadding: CGFloat = 2

    static let labelFont: CGFloat = 8
    static let labelTracking: CGFloat = 1.7
    static let valueFont: CGFloat = 12
    /// Instrument markings, not illustrations.
    static let glyph: CGFloat = 13
    static let microGlyph: CGFloat = 8

    static let pressOffset: CGFloat = 1.5
    /// Icon-only keys stay near-square. Wide enough that a four-character
    /// legend sets without ellipsizing — a truncated panel marking is worse
    /// than no marking.
    static let iconKeyWidth: CGFloat = 38
    /// Centred keys carry their legend edge-to-edge, so they use a tighter
    /// inset than the leading-aligned keys on the keybed.
    static let centredInset: CGFloat = 4
}

/// Matte, restrained, industrial. Flat fills — a gradient on every face is what
/// makes a panel look rendered instead of moulded.
enum TEKeyTone {
    case light
    case dark

    /// Pearl key white: bright and clearly a step above the panel it is
    /// mounted in. The dark key is charcoal, not black — the hardware's black
    /// keys read as a different moulding, not as a hole.
    var face: Color {
        switch self {
        case .light: Color.dynamic(light: 0xFFFDFE, dark: 0x525252)
        case .dark: Color.dynamic(light: 0x2B2B29, dark: 0x1B1B1B)
        }
    }

    /// The face's lower end. Three percent, no more.
    var faceLow: Color {
        switch self {
        case .light: Color.dynamic(light: 0xF1EDF2, dark: 0x4B4B4B)
        case .dark: Color.dynamic(light: 0x232321, dark: 0x151515)
        }
    }

    var facePressed: Color {
        switch self {
        case .light: Color.dynamic(light: 0xE8E4EA, dark: 0x3C3C3C)
        case .dark: Color.dynamic(light: 0x1A1A18, dark: 0x0F0F0F)
        }
    }

    var facePressedLow: Color {
        switch self {
        case .light: Color.dynamic(light: 0xDFDBE1, dark: 0x383838)
        case .dark: Color.dynamic(light: 0x151513, dark: 0x0C0C0C)
        }
    }

    /// The shade the housing casts across a key that has gone down.
    var pressShade: Color {
        switch self {
        case .light: Color.black.opacity(0.16)
        case .dark: Color.black.opacity(0.5)
        }
    }

    /// A single lit pixel along the top shoulder — the only highlight a matte
    /// moulded key gets.
    var topHighlight: Color {
        switch self {
        case .light: Color.dynamic(light: 0xFFFFFF, dark: 0x6E6E6E)
        case .dark: Color.white.opacity(0.14)
        }
    }

    /// The key's lower edge where it meets the rail.
    var bottomEdge: Color {
        switch self {
        case .light: Color.dynamic(light: 0xBBB5BE, dark: 0x303030)
        case .dark: Color.black.opacity(0.7)
        }
    }

    /// Legends are deliberately low contrast; values are deliberately high.
    var labelInk: Color {
        switch self {
        case .light: Color.dynamic(light: 0x7A757D, dark: 0x9E9E9E)
        case .dark: Color.dynamic(light: 0x93918B, dark: 0x858585)
        }
    }

    var valueInk: Color {
        switch self {
        case .light: Color.dynamic(light: 0x202022, dark: 0xF2F1EE)
        case .dark: Color.dynamic(light: 0xF5F3EF, dark: 0xEDECE9)
        }
    }
}

/// The seam between adjacent keys and the outline around a bank. On the real
/// hardware this is a soft shadow gap between two mouldings, not an inked line.
enum TERail {
    /// The gap between two mouldings reads as shadow, not as a drawn rule —
    /// a light seam let neighbouring keys blur into one slab.
    static let seam = Color.dynamic(light: 0xA39DA6, dark: 0x101010)
    static let outline = Color.dynamic(light: 0xA7A1AA, dark: 0x121212)
    /// The rail's own surface behind and between the key banks.
    static let deck = Color.dynamic(light: 0xE8E5EA, dark: 0x2F2F2F)
    /// Group boundary rule on the bare deck.
    static let rule = Color.dynamic(light: 0xB7B1BA, dark: 0x1E1E1E)
    static let ruleLight = Color.dynamic(light: 0xFFFFFF, dark: 0x454545)
    /// One functional accent, used the way the hardware uses it: a single mark,
    /// never a coloured surface.
    static let accent = Color.dynamic(light: 0xE85D1F, dark: 0xFF7040)
}

private struct InstrumentPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct InstrumentLatchedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Published by `InstrumentPressStyle`, consumed by every face that draws
    /// its own chrome. This is what lets a face built deep inside a menu or a
    /// popover-backed control know it is being pressed without threading a
    /// binding through every call site.
    var instrumentPressed: Bool {
        get { self[InstrumentPressedKey.self] }
        set { self[InstrumentPressedKey.self] = newValue }
    }

    /// Set on a control whose ON state is physical: a persistent switch, a
    /// latched toggle, or the selected key of a bank. The face stays DOWN
    /// while the value is true — hover must never raise it again.
    var instrumentLatched: Bool {
        get { self[InstrumentLatchedKey.self] }
        set { self[InstrumentLatchedKey.self] = newValue }
    }
}

// MARK: Key face

/// The pressable surface of a rail key. No corner radius and no outer border —
/// `TEKeyGroup` owns both, which is what stops two neighbours drawing a doubled
/// edge between them.
///
/// Pressed behaviour is a real key's: down 1pt, surface darkens slightly, the
/// top highlight goes out. No blur, no glow, no scale.
struct TEKeyFace: ViewModifier {
    var tone: TEKeyTone
    @Environment(\.instrumentPressed) private var pressed
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity)
            // Matte, but not flat paint: three percent of luminance across the
            // face is what separates a moulded part from a filled rectangle,
            // and it is still far short of a rendered gradient.
            .background(
                LinearGradient(colors: pressed
                               ? [tone.facePressed, tone.facePressedLow]
                               : [tone.face, tone.faceLow],
                               startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                // Pressed, the key takes a shadow from the housing above it
                // instead of a highlight — it has gone INTO the panel.
                Group {
                    if pressed {
                        LinearGradient(colors: [tone.pressShade, tone.pressShade.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 5)
                    } else {
                        Rectangle().fill(tone.topHighlight).frame(height: 1)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(tone.bottomEdge)
                    .frame(height: 1.5)
                    .opacity(pressed ? 0.35 : 1)
            }
            .offset(y: pressed ? TE.pressOffset : 0)
            // The legend goes quiet on a disabled key; the moulding does not
            // fade, because the key is still physically there.
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Rectangle())
    }
}

extension View {
    func teKeyFace(_ tone: TEKeyTone = .light) -> some View {
        modifier(TEKeyFace(tone: tone))
    }
}

// MARK: Key content

/// The inside of a key: a tiny engraved legend over a high-contrast value, both
/// on the rail's shared baseline grid. Reserving both rows unconditionally is
/// what keeps every legend and every value on one line across the whole rail,
/// including on keys that carry only a glyph.
struct TEKeyContent<Value: View>: View {
    var label: String?
    var tone: TEKeyTone = .light
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var value: () -> Value

    var body: some View {
        VStack(alignment: alignment, spacing: TE.labelToValue) {
            Text((label ?? " ").uppercased())
                .font(.system(size: TE.labelFont, weight: .medium, design: .monospaced))
                .tracking(TE.labelTracking)
                .foregroundStyle(tone.labelInk)
                .lineLimit(1)
                .frame(height: TE.labelRow, alignment: .bottom)
                .opacity(label == nil ? 0 : 1)
                .accessibilityHidden(true)
            value()
                .font(.system(size: TE.valueFont, weight: .medium))
                .foregroundStyle(tone.valueInk)
                .lineLimit(1)
                .frame(height: TE.valueRow)
        }
        .padding(.horizontal, alignment == .leading ? TE.horizontalInset : TE.centredInset)
        .padding(.vertical, TE.keyVPadding)
        .frame(maxWidth: .infinity,
               alignment: alignment == .leading ? .leading : .center)
    }
}

/// A complete rail key: legend, value, face and press behaviour in one
/// pressable surface. Use this unless the control needs to own its own
/// presentation (a popover-backed key builds `TEKeyContent` inside its own
/// Button instead, so there is still exactly one button).
struct TEControlKey<Value: View>: View {
    var label: String?
    var tone: TEKeyTone = .light
    var alignment: HorizontalAlignment = .leading
    var width: CGFloat?
    var help: String
    var action: () -> Void
    @ViewBuilder var value: () -> Value

    var body: some View {
        Button(action: action) {
            TEKeyContent(label: label, tone: tone, alignment: alignment, value: value)
                .frame(width: width)
                .teKeyFace(tone)
        }
        .buttonStyle(InstrumentPressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Key group

/// A bank of keys cut into the rail as one part.
///
/// The group owns ALL of the geometry: the outer radius, the outline, and the
/// seams between keys. Keys are laid out `TE.seam` apart over a seam-coloured
/// backing, so the gap between two neighbours is the housing showing through —
/// one crisp physical pixel, never two adjacent borders.
struct TEKeyGroup<Content: View>: View {
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TE.keyRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: TE.seam) {
            content
        }
        .frame(height: TE.keyHeight)
        .background(TERail.seam)
        .clipShape(shape)
        .overlay(shape.strokeBorder(TERail.outline, lineWidth: 1))
        // A moulded part sits in the panel; it does not float above it. One
        // short contact shadow, no blur halo.
        .shadow(color: Color.black.opacity(0.22), radius: 1, y: 1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A group boundary on the bare deck: a machined rule, not a list separator.
struct TERule: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(TERail.rule).frame(width: 1)
            Rectangle().fill(TERail.ruleLight).frame(width: 1)
        }
        .frame(height: TE.keyHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Instrument key material (round caps and utility buttons)
//
// Everything OUTSIDE the rail — toolbar keys, the send cap, the navigation
// spine, app-wide action buttons — keeps the moulded-cap material: a nearly
// flat face whose physicality lives on its edges, a lit top lip, a shadowed
// front wall, and a short contact shadow onto the deck.

/// Silver caps are ordinary keys; dark caps are the primary ones.
enum InstrumentKeyTone {
    case silver
    case dark
}

struct InstrumentKeyMaterial<S: InsettableShape>: ViewModifier {
    let shape: S
    var tone: InstrumentKeyTone = .silver
    /// Multiplies the contact shadow so a primary cap can sit proud of its
    /// neighbours without changing its material.
    var elevation: CGFloat = 1
    @Environment(\.instrumentPressed) private var pressed
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(shape.fill(LinearGradient(
                colors: pressed ? [pressedTop, pressedBottom] : [top, bottom],
                startPoint: .top, endPoint: .bottom)))
            // The cap's own walls. Looking down at a key you see a lit top edge
            // and a SHADOWED front wall along the bottom — the asymmetry is the
            // whole illusion. Lighting both edges flattens it into a rectangle.
            .overlay(shape.inset(by: 0.5).strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: lip.opacity(pressed ? 0.10 : 1), location: 0),
                        .init(color: .clear, location: 0.34),
                        .init(color: .clear, location: 0.60),
                        .init(color: wall.opacity(pressed ? 0.40 : 1), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 2))
            .overlay(shape.strokeBorder(rim, lineWidth: contrast == .increased ? 1.5 : 0.75))
            // A key that has gone down shows the panel's shadow across its
            // upper shoulder: the narrow dark recess above the depressed face.
            .overlay(alignment: .top) {
                if pressed {
                    LinearGradient(colors: [Color.black.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 4)
                        .clipShape(shape)
                }
            }
            // One group so the shadow is cast by the cap's silhouette rather
            // than by the glyph sitting on it.
            .compositingGroup()
            // Down, the contact shadow is gone: the key is seated IN the
            // panel, so nothing floats beneath it.
            .shadow(color: Instrument.keySocket.opacity(pressed ? 0 : 1),
                    radius: (pressed ? 0 : 2.2) * elevation,
                    y: (pressed ? 0 : 1.8) * elevation)
            .offset(y: pressed && !reduceMotion ? 1 : 0)
            // A disabled key is still a key — it is the LABEL that goes dark,
            // not the moulding.
            .opacity(isEnabled ? 1 : 0.72)
    }

    private var top: Color { tone == .dark ? Instrument.darkKeyTop : Instrument.keyTop }
    private var bottom: Color { tone == .dark ? Instrument.darkKeyBottom : Instrument.keyBottom }
    private var pressedTop: Color {
        tone == .dark ? Instrument.darkKeyTopPressed : Instrument.keyTopPressed
    }
    private var pressedBottom: Color {
        tone == .dark ? Instrument.darkKeyBottomPressed : Instrument.keyBottomPressed
    }
    private var lip: Color { tone == .dark ? Color.white.opacity(0.55) : Instrument.keyLip }
    /// The shadowed front wall along the cap's lower edge.
    private var wall: Color { tone == .dark ? Color.black : Instrument.keyWall }
    private var rim: Color { tone == .dark ? Color.black.opacity(0.75) : Instrument.keyRim }
}

extension View {
    /// Wear the moulded-cap material. Pass the silhouette you want —
    /// `RoundedRectangle` for panel keys, `Circle` for caps — and the
    /// construction stays identical across all of them.
    func instrumentKey<S: InsettableShape>(
        _ shape: S,
        tone: InstrumentKeyTone = .silver,
        elevation: CGFloat = 1
    ) -> some View {
        modifier(InstrumentKeyMaterial(shape: shape, tone: tone, elevation: elevation))
    }
}
