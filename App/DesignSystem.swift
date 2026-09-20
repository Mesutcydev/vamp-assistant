import SwiftUI

// MARK: - Shared Vamp Assistant component system
//
// One vocabulary for every screen: toolbar controls, search fields, tags,
// outline cards, section labels, and page shells. Screens compose these
// instead of hand-styling equivalents, so the chat, settings, model library,
// and bots pages read as one product. Values come from `Chrome`/`Radius`/
// `Theme`, which mirror the exported reference artboard.

/// Press feedback for frameless marks printed on a surface (composer source
/// marks, sidebar keys): a small dip, no chrome change. The window's top bar
/// no longer uses it — that band is the system toolbar now.
struct ToolbarMarkPressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.textPrimary.opacity(isEnabled ? (configuration.isPressed ? 0.12 : (hovering ? 0.06 : 0)) : 0))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

/// Compact search field. One implementation, one metric source: the history
/// drawer passes its own height, the settings/library filters keep the default.
struct VampSearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil
    var focus: FocusState<Bool>.Binding? = nil
    var minHeight: CGFloat? = nil
    var cornerRadius: CGFloat = SidebarMetrics.searchRadius
    /// Goes on the field itself: an identifier on this composite would land
    /// on the group, where a `textFields` query never looks.
    var identifier: String? = nil
    @FocusState private var localFocus: Bool

    private var focused: Bool { focus?.wrappedValue ?? localFocus }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: SidebarMetrics.searchIcon, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.appUI(size: SidebarMetrics.searchText))
                        .foregroundStyle(Theme.placeholderOnSilver)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.appUI(size: SidebarMetrics.searchText))
                    .foregroundStyle(Instrument.ink)
                    .accessibilityLabel(placeholder)
                    .accessibilityIdentifier(identifier ?? "")
                    .focused(focus ?? $localFocus)
                    .onSubmit { onSubmit?() }
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, SidebarMetrics.searchPadding)
        .frame(height: minHeight ?? Chrome.searchHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Instrument.recessFill.opacity(0.85)))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(focused ? Instrument.accentOrange : Instrument.seam.opacity(0.7),
                              lineWidth: focused ? 1 : 0.75))
    }
}

/// Compact instrument selector, built on the native segmented `Picker`.
///
/// A custom key row lived here originally. SwiftUI merged the keys'
/// accessibility frames into the container, so XCUITest saw the right
/// elements but every coordinate click landed on the first key — provider
/// and appearance switching could not be driven from UI tests. The native
/// control keeps each segment individually hittable.
struct InstrumentSegmentedControl<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(title: String, value: Selection)]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].title)
                    .tag(options[index].value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("instrument-segmented")
    }
}

/// Quiet text field: recessed well with an 8pt radius — the same family as
/// the composer's editor recess and the sidebar search well.
extension View {
    func vampField(height: CGFloat = Chrome.buttonHeight) -> some View {
        self
            .textFieldStyle(.plain)
            .font(.app(size: 12.5 ))
            .foregroundStyle(Instrument.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous)
                    .fill(Instrument.recessFill.opacity(0.85)))
            .overlay(
                RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous)
                    .strokeBorder(Instrument.seam.opacity(0.7), lineWidth: 0.75))
    }
}

// MARK: - Instrument material system
//
// The approved composer defines the product's materials. These primitives
// reuse its construction at smaller scales: silver faceplates for primary
// modules, recessed wells for working areas, dark inserts for selected
// controls. Ordinary rows never receive the composer's full hardware detail.

/// Menu trigger with a REAL custom face.
///
/// On current macOS, `Menu` re-templates its label through AppKit and strips
/// fills, strokes, and shadows from it — any shape-bearing face (a capsule,
/// the raised dial, a status dot) flattens to bare text, and an all-shape
/// label (the dial) disappears entirely. This control keeps the face a
/// first-class Button and presents the options in a popover, so the
/// instrument chrome survives and the options keep native dismissal.
struct InstrumentMenu<Face: View, Options: View>: View {
    @ViewBuilder var face: () -> Face
    @ViewBuilder var options: () -> Options
    var menuWidth: CGFloat = 240
    @State private var open = false

    init(menuWidth: CGFloat = 240,
         @ViewBuilder face: @escaping () -> Face,
         @ViewBuilder options: @escaping () -> Options) {
        self.menuWidth = menuWidth
        self.face = face
        self.options = options
    }

    var body: some View {
        Button {
            open = true
        } label: {
            face()
        }
        .buttonStyle(InstrumentPressStyle())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                options()
            }
            .padding(6)
            .frame(width: menuWidth)
        }
    }
}

/// One selectable row inside an `InstrumentMenu`. Silver row, hover lift,
/// checkmark carries the selected state; destructive rows tint red.
struct InstrumentMenuRow: View {
    let title: String
    var systemImage: String? = nil
    var isSelected: Bool = false
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            guard !isDisabled else { return }
            action()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16)
                        .foregroundStyle(isDestructive
                                         ? Theme.negative
                                         : (isSelected ? Theme.accentText : Instrument.inkSecondary))
                }
                Text(title)
                    .font(.appUI(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isDestructive
                                     ? Theme.negative
                                     : (isDisabled ? Instrument.inkSecondary : Instrument.ink))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accentText)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 27)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering && !isDisabled ? Instrument.recessFill.opacity(0.9) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .pointerStyle(hovering && !isDisabled ? .link : .default)
        .help(help ?? title)
        .accessibilityLabel(title)
        .accessibilityHint(isDisabled ? "Unavailable for the current chat" : "")
    }
}

extension View {
    /// Silver faceplate: vertical metal gradient, bright top edge, dark
    /// bottom edge, fine seam outline, shallow directional shadow.
    func instrumentFaceplate(radius: CGFloat = 8,
                             shadow: Bool = true) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Instrument.silverTop, Instrument.silverMid, Instrument.silverLow],
                        startPoint: .top, endPoint: .bottom)))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Instrument.seamLight, Instrument.seam,
                                                Instrument.silverEdgeDark],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
            .shadow(color: shadow ? Theme.cardShadow : .clear,
                    radius: shadow ? 3 : 0, y: shadow ? 1 : 0)
    }

    /// Recessed working well: gray cavity with inset shading, for editors,
    /// search, fields, code, and console bodies.
    func instrumentRecess(radius: CGFloat = 6) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Instrument.recessFill))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Instrument.seam.opacity(0.8), lineWidth: 1))
    }

    /// Dark inserted control surface (selected capsules, primary actions).
    func instrumentInsert(radius: CGFloat = 999) -> some View {
        self
            .background(Capsule().fill(Instrument.darkInsert))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75))
    }

    /// Engraved vertical seam between instrument cells.
    func instrumentSeamTrailing() -> some View {
        self.overlay(alignment: .trailing) {
            Rectangle()
                .fill(Instrument.seam.opacity(0.5))
                .frame(width: 0.75)
                .padding(.vertical, 8)
        }
    }
}

/// Compact signal readout: LED + spaced micro-label, truthful state only.
struct InstrumentSignal: View {
    let label: String
    let on: Bool
    var tint: Color = Instrument.signalGreen

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(on ? tint : Instrument.signalIdle)
                .frame(width: 5, height: 5)
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Instrument.engraved)
        }
        .accessibilityLabel("\(label): \(on ? "active" : "inactive")")
    }
}

/// Quiet metadata tag for cards (model specs, formats, states). One shape
/// everywhere: solid inset fill, 8pt radius, tertiary text.
struct VampTag: View {
    let text: String
    var tint: Color? = nil
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 10.5, weight: .medium, design: .monospaced)
                             : .app(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint ?? Instrument.inkSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Instrument.recessFill.opacity(0.8)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Instrument.seam.opacity(0.6), lineWidth: 0.5))
    }
}

/// Small status dot + label pair (connection, run state, availability).
struct VampStatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        InstrumentLamp(color: color, bore: size + 3)
    }
}

/// A panel lamp: a lens seated in a drilled bore, not a dot painted on the
/// surface. The bore's upper wall is shadowed and its lower wall catches light,
/// which is what separates an indicator from a coloured circle.
struct InstrumentLamp: View {
    let color: Color
    var bore: CGFloat = 8
    var live: Bool = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Instrument.recessFill)
                .overlay(Circle().inset(by: 0.4).strokeBorder(
                    LinearGradient(colors: [Instrument.keyWall,
                                            Instrument.keyLip.opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8))
                .frame(width: bore, height: bore)
            if live {
                InstrumentLiveSignal(active: true, tint: color)
                    .frame(width: bore / 2, height: bore / 2)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: bore / 2, height: bore / 2)
            }
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The one outline card is now a silver faceplate: engraved seam,
    /// machined gradient, no floating shadow. Used by settings groups,
    /// plan/approval modules, model slots, and dashboard panels.
    func vampOutlineCard(padding: EdgeInsets = EdgeInsets(
        top: Chrome.cardVPadding, leading: Chrome.cardHPadding,
        bottom: Chrome.cardVPadding, trailing: Chrome.cardHPadding)
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentFaceplate(radius: Radius.card, shadow: false)
    }

    /// Uppercase eyebrow label: 10pt semibold, 0.9 tracking. On silver
    /// faceplates use `Instrument.microLabel` (engraved) instead.
    func vampSectionLabel() -> some View {
        self
            .font(.app(size: 10, weight: .semibold ))
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(Theme.textSecondary)
    }

    /// Centered page column with the reference's page padding. Settings and
    /// dashboard content share the transcript's 700pt reading width so no
    /// screen runs full-bleed.
    func vampPageColumn() -> some View {
        self
            .frame(maxWidth: Chrome.pageMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Chrome.pageHPadding)
            .padding(.top, Chrome.pageTopPadding)
            .padding(.bottom, Chrome.pageBottomPadding)
    }
}

/// Grouped section inside a page: eyebrow label + outline card. One rhythm
/// for every settings group and dashboard panel.
struct VampSection<Content: View>: View {
    let label: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(label)
                .vampSectionLabel()
                .padding(.leading, 2)
            content
                .vampOutlineCard()
            if let footer {
                Text(footer)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Compact labeled row for grouped cards: label left, control right, uniform
/// 30pt rhythm. Settings rows, bot capability rows, and detail fields share
/// it so every label/control pair aligns identically.
struct VampRow<Control: View>: View {
    let label: String
    var value: String? = nil
    @ViewBuilder var control: Control
    @State private var availableWidth: CGFloat = 800

    var body: some View {
        let layout = availableWidth < 560
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.md))
        layout {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.app(size: 13 ))
                    .foregroundStyle(Instrument.ink)
                if let value {
                    // Descriptions wrap; only single-line identifiers
                    // (paths, model ids) truncate, and never mid-word here.
                    Text(value)
                        .font(.app(size: 11 ))
                        .foregroundStyle(Instrument.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .frame(maxWidth: 420, alignment: availableWidth < 560 ? .leading : .trailing)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .frame(minHeight: 30)
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Instrument.seam.opacity(0.28))
                .frame(height: 0.5)
        }
    }
}
