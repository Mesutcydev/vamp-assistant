import AppKit
import SwiftUI

// MARK: - Shared sidebar geometry

/// One set of numbers for every sidebar/drawer surface in the window — the
/// Settings navigation column and the History drawer. Only the outermost
/// surface owns the window corners: nothing here draws an outer border or a
/// second rounded container, so the sidebar is clipped by AppKit's window
/// mask instead of stacking its own radius inside it.
enum SidebarMetrics {
    /// Default expanded width for the conversation library. Users who
    /// resized it keep their saved width; new installs start here.
    static let width: CGFloat = 272
    static let minWidth: CGFloat = 248
    static let maxWidth: CGFloat = 320
    /// The permanent left navigation rail. Narrow by design: it is the width
    /// its controls need, so the drawer and the canvas keep everything else.
    static let collapsedWidth: CGFloat = 46
    /// Invisible pointer target. Visibly the rail is denser than this, but a
    /// 28pt face alone would be an unkind click target.
    static let railTarget: CGFloat = 38
    /// Visible button surface.
    static let railFace: CGFloat = InstrumentScale.mark
    static let railIcon: CGFloat = InstrumentScale.markGlyph
    /// A half-pixel optical step for glyphs that read long or short.
    static let railIconOpticalStep: CGFloat = 0.5
    static let railRadius: CGFloat = 5
    static let railMarkerWidth: CGFloat = 2
    static let railMarkerHeight: CGFloat = 14
    static let railMarkerInset: CGFloat = 0
    /// Vertical gap between adjacent navigation faces. Tight, but the 28pt
    /// face in a 38pt target still leaves each control comfortably clickable.
    static let railItemGap: CGFloat = 7
    /// Distance from the window's top edge to the first navigation face —
    /// tight, so New chat sits at the window's top-left corner.
    static let railTopInset: CGFloat = 8
    /// Spec for the hardware spine stacked under the rail: perforation grid,
    /// circular controls, and their spacing all come from here.
    static let grilleDot: CGFloat = 2.2
    static let grilleDotGap: CGFloat = 2.5
    /// Seven columns keep the etched grille at ~27pt — quieter and narrower
    /// than the panel it replaced, without losing the pattern.
    static let grilleColumnCount: Int = 7
    static let grilleRowCount: Int = 5
    static let grilleTopInset: CGFloat = 10
    static let grilleBottomInset: CGFloat = 8
    static let hardwareFace: CGFloat = 29
    static let hardwareIcon: CGFloat = 11
    static let hardwareGap: CGFloat = 6
    /// Space between Settings and the hardware stack. Settings belongs to
    /// navigation, so it sits close to the section it introduces.
    static let hardwareSectionGap: CGFloat = 10

    /// What a `.sidebar`-style list adds to a row's leading edge on its own.
    /// Measured, not guessed: a row asking for 48 renders its content at 63, so
    /// a row that has to land on the navigation axis asks for the difference.
    static let sidebarListInset: CGFloat = 15

    /// Outer horizontal content inset for every sidebar region.
    static let inset: CGFloat = 12
    /// Row background edge → icon/title anchor.
    static let rowPadding: CGFloat = 8

    // MARK: Navigation rows
    //
    // One alignment grid for every row in the column, on a 4pt scale. The
    // glyph column has to be wider than the glyphs it holds: at 14 the 13pt
    // conversational symbols (bubble.left.and.bubble.right is ~18pt wide) burst
    // their frame, swallowed the gap and collided with the label, which also
    // left every label optically off its axis. 20pt centres every symbol with
    // slack to spare, and the label axis lands on 48:
    //   fill 8 + content 10 + glyph 20 + gap 10 = 48.
    static let navRowFillInset: CGFloat = 8
    static let navRowContentInset: CGFloat = 10
    static let navGlyphColumn: CGFloat = 20
    static let navGlyphGap: CGFloat = 10
    /// Where every navigation label starts, measured from the column's edge.
    static let navLabelAxis: CGFloat = navRowFillInset + navRowContentInset
        + navGlyphColumn + navGlyphGap
    /// Vertical rhythm between navigation rows: a 32pt row every 36pt, so the
    /// rows read as a list instead of a stack of touching bars.
    static let navRowSpacing: CGFloat = 4
    /// Breathing room above the first row and below the last.
    static let navRowsTopInset: CGFloat = 8
    static let navRowsBottomInset: CGFloat = 8
    /// One conversation row. The drawer is information, not hardware: it is
    /// dense so more history is visible without reading smaller type.
    static let rowHeight: CGFloat = 32
    static let iconWidth: CGFloat = 18
    static let iconGap: CGFloat = Spacing.sm
    /// Selected rows stay deliberately tighter than the window/sidebar
    /// geometry above them — a card-sized radius reads as a nested panel.
    static let selectionRadius: CGFloat = 6

    // MARK: History drawer
    //
    // The drawer is information next to a hardware rail: one continuous
    // material, quiet separators, and a single alignment grid. Every control
    // below is intrinsically sized and shares the row's text axis.
    /// Header title band.
    static let headerHeight: CGFloat = 36
    /// Workspace selector row. Matches the navigation rows' height so the
    /// project control sits in the same rhythm as the destinations.
    static let workspaceRowHeight: CGFloat = 32
    /// Search field.
    static let searchHeight: CGFloat = 30
    static let searchRadius: CGFloat = 7
    static let searchPadding: CGFloat = 9
    static let searchIcon: CGFloat = 12.5
    static let searchText: CGFloat = 12.5
    /// "New chat" command row and the collapsible project rows.
    static let commandRowHeight: CGFloat = 28
    /// Date headings: tiny organisational labels, not banners.
    static let sectionHeaderHeight: CGFloat = 20
    static let sectionHeaderText: CGFloat = 9
    static let sectionHeaderTracking: CGFloat = 1.5
    /// Trailing action slot. Reserved so titles never reflow when the actions
    /// menu fades in on hover or selection.
    static let rowActionSlot: CGFloat = 26
    static let rowActionHit: CGFloat = 24
    static let rowActionIcon: CGFloat = 12
    /// Bottom connection rail.
    static let connectionRailHeight: CGFloat = 30
    static let statusDot: CGFloat = 6
}

extension View {
    /// The one sidebar surface: a full-height navigation plane that runs to the
    /// window's leading, top and bottom edges. The system's macOS 26 floating
    /// panel appearance is off (see `BeetCodeAppDelegate`), so this surface
    /// owns the column — no inner rounded rectangle and no second border
    /// parallel to the window edge.
    func sidebarSurface() -> some View {
        modifier(SidebarGlassSurface())
    }
}

private struct SidebarGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if !reduceTransparency && contrast != .increased {
                        Rectangle().fill(.regularMaterial)
                    }
                    LinearGradient(
                        colors: [Theme.navigationTop.opacity(reduceTransparency ? 1 : 0.72),
                                 Theme.navigationBottom.opacity(reduceTransparency ? 1 : 0.78)],
                        startPoint: .top, endPoint: .bottom)
                    LinearGradient(
                        colors: [Color.white.opacity(colorScheme == .dark ? 0.08 : 0.58),
                                 Color.clear, Color.clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
            }
    }
}

/// The one vertical divider between a sidebar and the region beside it:
/// an engraved instrument seam.
struct SidebarSplitDivider: View {
    var width: Binding<CGFloat>? = nil
    var range: ClosedRange<CGFloat> = 240...380

    @State private var dragOrigin: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Instrument.seam.opacity(0.7))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .overlay { if let width { handle(width) } }
    }

    private func handle(_ width: Binding<CGFloat>) -> some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? width.wrappedValue
                        dragOrigin = origin
                        width.wrappedValue = min(max(origin + value.translation.width,
                                                     range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}

/// A separator inside a sidebar, inset so it stops short of the column's
/// vertical divider instead of colliding with it.
struct SidebarDivider: View {
    /// Pass 0 when the divider already sits inside a container carrying the
    /// sidebar inset, so it lines up with the rows instead of doubling it.
    var inset: CGFloat = SidebarMetrics.inset

    var body: some View {
        Rectangle()
            .fill(Instrument.seam.opacity(0.6))
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

/// One navigation row on the sidebar surface: glyph on the column's icon axis,
/// label on its text axis, and a fill that belongs to the surface rather than a
/// panel inside it. Selection is a soft neutral lift with the accent on the
/// glyph — the same language the destination column and the Settings row share.
struct SidebarNavRow: View {
    let title: String
    let systemImage: String
    var isSelected: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.navGlyphGap) {
                Image(systemName: systemImage)
                    .font(.appUI(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accentText : Theme.textSecondary)
                    // Centred in the column, so symbols of different widths
                    // share one optical axis and every label starts together.
                    .frame(width: SidebarMetrics.navGlyphColumn, alignment: .center)
                Text(title)
                    .font(.appUI(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SidebarMetrics.navRowContentInset)
            .frame(maxWidth: .infinity,
                   minHeight: SidebarMetrics.rowHeight,
                   alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius,
                                                   style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarMetrics.navRowFillInset)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var fill: Color {
        if isSelected { return Theme.washStrong(Theme.accent) }
        return hovering ? Theme.navigationRowHover : .clear
    }
}

/// macOS 26 draws the sidebar column as a panel with a rounded top-left corner
/// and a shadow around it. A shadow falls *over* whatever is painted behind it,
/// which is why the navigation surface painted there still came out black in
/// OLED: the window behind the panel is pure black, the shadow deepens it, and
/// the corner reads as a dark notch bitten out of the column.
///
/// So the corner is painted *on top* instead: the navigation plane masked to the
/// little corner square that lies outside the panel's arc. Inside the arc the
/// panel itself is untouched; outside it the window shows navigation surface
/// rather than a shadow on black.
struct SidebarCornerPatch: View {
    /// Which of the panel's leading corners this patch covers. macOS 26 rounds
    /// the column at every corner, and the window shows through outside each
    /// arc, so both leading corners need the same treatment.
    enum Corner {
        case topLeading
        case bottomLeading
    }

    var corner: Corner = .topLeading

    /// How much of the corner is repainted. Large enough to swallow the
    /// shadow, still short of the first row (which starts at x=8, y=8 of the
    /// content area).
    static let size: CGFloat = 24
    /// The system's own arc is about 20; matching it means the mask boundary
    /// falls inside the panel, where repainting the same plane is invisible.
    static let arc: CGFloat = 22

    var body: some View {
        ZStack(alignment: .leading) {
            (corner == .topLeading ? Theme.navigationTop : Theme.navigationBottom)
                .mask {
                    Rectangle()
                        .overlay(alignment: corner == .topLeading ? .bottomTrailing : .topTrailing) {
                            Circle()
                                .frame(width: Self.arc * 2, height: Self.arc * 2)
                                .offset(x: Self.arc, y: corner == .topLeading ? Self.arc : -Self.arc)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }
            // The column's own edge line runs down its leading edge, and this
            // patch paints over the span beside the corner — which cut the line
            // off exactly where the eye is looking. Redraw that span so the
            // edge runs unbroken into the window's corner.
            Rectangle()
                .fill(Instrument.seam)
                .frame(width: 1)
        }
    }
}
