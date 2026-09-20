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

    /// Outer horizontal content inset for every sidebar region.
    static let inset: CGFloat = 12
    /// Row background edge → icon/title anchor.
    static let rowPadding: CGFloat = 8
    /// One conversation row. The drawer is information, not hardware: it is
    /// dense so more history is visible without reading smaller type.
    static let rowHeight: CGFloat = 30
    static let iconWidth: CGFloat = 18
    static let iconGap: CGFloat = Spacing.sm
    /// Selected rows stay deliberately tighter than the window/sidebar
    /// geometry above them — a card-sized radius reads as a nested panel.
    static let selectionRadius: CGFloat = 5

    // MARK: History drawer
    //
    // The drawer is information next to a hardware rail: one continuous
    // material, quiet separators, and a single alignment grid. Every control
    // below is intrinsically sized and shares the row's text axis.
    /// Header title band.
    static let headerHeight: CGFloat = 36
    /// Workspace selector row.
    static let workspaceRowHeight: CGFloat = 29
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
    /// The one sidebar surface. It extends through the split view's top,
    /// leading, and bottom container inset so the material runs underneath
    /// the titlebar and into the window's corner mask — no inner rounded
    /// rectangle, no second border parallel to the window edge.
    /// The sidebar is a silver side module in the navigation-surface family.
    func sidebarSurface() -> some View {
        background {
            LinearGradient(colors: [Instrument.silverTop,
                                    Theme.navigationSurface,
                                    Instrument.silverLow.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
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
