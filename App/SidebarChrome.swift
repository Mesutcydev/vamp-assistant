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
    /// Collapsed utility rail width (matches the Settings rail family).
    static let collapsedWidth: CGFloat = 64
    static let railTarget: CGFloat = 44
    static let railFace: CGFloat = 28
    static let railIcon: CGFloat = 16
    static let railRadius: CGFloat = 6
    static let railMarkerWidth: CGFloat = 2
    static let railMarkerHeight: CGFloat = 14
    static let railMarkerInset: CGFloat = 2

    /// Outer horizontal content inset for every sidebar region.
    static let inset: CGFloat = 12
    /// Row background edge → icon/title anchor.
    static let rowPadding: CGFloat = 10
    static let rowHeight: CGFloat = 34
    static let iconWidth: CGFloat = 18
    static let iconGap: CGFloat = Spacing.sm
    /// Selected rows stay deliberately tighter than the window/sidebar
    /// geometry above them — a card-sized radius reads as a nested panel.
    static let selectionRadius: CGFloat = 5
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
