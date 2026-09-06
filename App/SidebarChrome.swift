import AppKit
import SwiftUI

// MARK: - Shared sidebar geometry

/// One set of numbers for every sidebar/drawer surface in the window — the
/// Settings navigation column and the History drawer. Only the outermost
/// surface owns the window corners: nothing here draws an outer border or a
/// second rounded container, so the sidebar is clipped by AppKit's window
/// mask instead of stacking its own radius inside it.
enum SidebarMetrics {
    /// The canonical sidebar width — one constant for the History drawer and
    /// the Settings navigation column, so no screen shows a slightly
    /// different sidebar. ~23% of the 1240pt default window.
    static let width: CGFloat = 280
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 360

    /// Axis A/B: the gap between the sidebar edge and every piece of content
    /// inside it — cards, rows, list rows, separators, footer. One value, so
    /// the repeated left and right edges actually repeat.
    static let inset: CGFloat = Spacing.md
    /// Row background edge → icon. The single horizontal anchor shared by the
    /// back chevron, navigation icons, labels, and selected fills.
    static let rowPadding: CGFloat = Spacing.sm
    static let rowHeight: CGFloat = 32
    /// A tab in the rail stands one step taller than a history row: it is a
    /// destination, tapped once and then lived in, not one of forty.
    static let railRowHeight: CGFloat = 34
    static let iconWidth: CGFloat = 18
    static let iconGap: CGFloat = Spacing.sm
    /// Selected rows stay deliberately tighter than the window/sidebar
    /// geometry above them — a card-sized radius reads as a nested panel.
    static let selectionRadius: CGFloat = Radius.sm
}

extension View {
    /// The one sidebar surface. It extends through the split view's top,
    /// leading, and bottom container inset so the material runs underneath
    /// the titlebar and into the window's corner mask — no inner rounded
    /// rectangle, no second border parallel to the window edge.
    func sidebarSurface() -> some View {
        background {
            Theme.surface
                .ignoresSafeArea(.container, edges: [.top, .leading, .bottom])
        }
    }
}

/// The one vertical divider between a sidebar and the region beside it.
///
/// It is a sibling of both regions in the window's root row, not the edge of a
/// nested panel, so it runs the full window height and meets the bottom edge
/// squarely. `width` makes it the drag handle that resizes the sidebar.
struct SidebarSplitDivider: View {
    var width: Binding<CGFloat>? = nil
    var range: ClosedRange<CGFloat> = 240...380

    @State private var dragOrigin: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
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
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, inset)
    }
}

/// One navigation row. The back action and the destination rows share it so
/// their chevrons, icons, labels, and selected backgrounds land on the same
/// anchors instead of drifting a few points apart.
struct SidebarNavRow: View {
    let title: String
    let icon: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: icon)
                    .font(.app(size: 13, weight: .medium, design: .serif))
                    .frame(width: SidebarMetrics.iconWidth)
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, SidebarMetrics.rowPadding)
            // One frame, leading-aligned. A separate `.frame(height:)` centers
            // horizontally, so a title wider than the column pushed its own row
            // left of every other row's anchor.
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.rowHeight, alignment: .leading)
            .background(selected ? Theme.surfaceInset : .clear,
                        in: RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius,
                                             style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Left tab rail

/// A section caption inside a rail. Same tier as the transcript's headings so
/// the two columns of the window agree on what a label looks like.
struct SidebarRailCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.7)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, SidebarMetrics.rowPadding)
            .padding(.top, Spacing.md)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One tab in a left rail.
///
/// A rail row is not a list row: the selected one has to read as the place you
/// are standing, from the corner of the eye, without a second window chrome to
/// help. So selection is three things at once — a filled well, an accent
/// marker on the leading edge, and the glyph switching to the accent — while
/// hover stays a whisper below that, and neither ever moves the label.
struct SidebarTabRow: View {
    let title: String
    let icon: String
    var selected: Bool = false
    var shortcut: KeyEquivalent?
    let action: () -> Void

    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SidebarMetrics.selectionRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarMetrics.iconGap) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: SidebarMetrics.iconWidth)
                    .foregroundStyle(selected ? Theme.accentText : Theme.textTertiary)
                Text(title)
                    .font(.body.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, SidebarMetrics.rowPadding)
            .frame(maxWidth: .infinity, minHeight: SidebarMetrics.railRowHeight, alignment: .leading)
            .background {
                if selected {
                    shape.fill(Theme.surfaceInset)
                } else if hovering {
                    shape.fill(Theme.surfaceInset.opacity(0.55))
                }
            }
            // The marker is an overlay, not a leading element: it must not
            // shift the glyph by its own width when selection moves.
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.accentText)
                    .frame(width: 2.5, height: 15)
                    .padding(.leading, 2)
                    .opacity(selected ? 1 : 0)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .modifier(OptionalKeyShortcut(key: shortcut))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// `keyboardShortcut` has no "no shortcut" argument, so the conditional lives
/// in a modifier rather than in a branch that would change the view's identity.
private struct OptionalKeyShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}
