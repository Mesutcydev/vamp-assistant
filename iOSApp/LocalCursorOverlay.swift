import SwiftUI

/// Local cursor overlay for streams requested with the host cursor omitted
/// (`cursor=0`). The pointer is drawn client-side at the exact positions the
/// input pipeline maps, so cursor and hover feedback are zero-round-trip:
/// the pointer leads and the video follows, instead of every movement waiting
/// for a captured frame round trip.
@MainActor
final class LocalCursorModel: ObservableObject {
    /// Cursor position in the video surface's coordinates, or nil when hidden.
    @Published private(set) var position: CGPoint?

    private var clampRect: CGRect = .zero

    func setSurface(contentRect: CGRect) {
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        clampRect = contentRect
        // This is called from a view builder (the GeometryReader that maps the letterboxed
        // content rect), so an unconditional write publishes during a view update: SwiftUI
        // re-runs the body, which calls this again, and the app spins at ~100% CPU — the
        // "Control Mac" freeze. `@Published` has no equality check, so assign only on change.
        let next = position.map(clampToContent) ?? CGPoint(x: contentRect.midX, y: contentRect.midY)
        if position != next { position = next }
    }

    /// Absolute placement: the exact view point a touch was mapped to.
    func place(at viewPoint: CGPoint) {
        position = clampToContent(viewPoint)
    }

    /// Relative placement: an already-accelerated desktop-space delta, scaled into
    /// view points via `viewPointsPerDesktopPoint`.
    func moveRelative(dx: Double, dy: Double, viewPointsPerDesktopPoint: Double) {
        guard let current = position else { return }
        position = clampToContent(CGPoint(
            x: current.x + dx * viewPointsPerDesktopPoint,
            y: current.y + dy * viewPointsPerDesktopPoint))
    }

    func hide() { position = nil }

    private func clampToContent(_ point: CGPoint) -> CGPoint {
        guard clampRect.width > 0, clampRect.height > 0 else { return point }
        return CGPoint(
            x: min(max(point.x, clampRect.minX), clampRect.maxX),
            y: min(max(point.y, clampRect.minY), clampRect.maxY))
    }
}

/// Compact macOS-style arrow. The local overlay sits above an already scaled
/// desktop stream, so it uses a smaller screen-space silhouette than the host
/// cursor. A graphite face and fine pearl rim keep it readable without turning
/// it into a large sticker over the content being controlled.
struct LocalCursorOverlay: View {
    @ObservedObject var cursor: LocalCursorModel
    /// The video is magnified by the caller, but the pointer glyph should remain
    /// a stable screen-space size like the macOS system cursor.
    var contentZoom: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let position = cursor.position {
                CursorArrowShape()
                    .fill(Color(red: 0.055, green: 0.055, blue: 0.065))
                    .overlay(CursorArrowShape().stroke(Color.white.opacity(0.94), lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.24), radius: 0.8, x: 0.35, y: 0.55)
                    .frame(width: 9.5, height: 14.5, alignment: .topLeading)
                    .scaleEffect(1 / max(contentZoom, 1), anchor: .topLeading)
                    .offset(x: position.x - 1, y: position.y - 0.75)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.88))
        path.addLine(to: CGPoint(x: w * 0.34, y: h * 0.67))
        path.addLine(to: CGPoint(x: w * 0.53, y: h))
        path.addLine(to: CGPoint(x: w * 0.70, y: h * 0.91))
        path.addLine(to: CGPoint(x: w * 0.51, y: h * 0.60))
        path.addLine(to: CGPoint(x: w * 0.84, y: h * 0.57))
        path.closeSubpath()
        return path
    }
}
