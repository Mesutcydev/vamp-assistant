import CoreGraphics
import Foundation

/// Aspect-fit / aspect-fill placement for remote Mac video, matching Vamp Control's
/// `DisplayMappingEngine` content-rect math so taps land on the right pixels.
enum RemoteDisplayMapping {
    enum Mode: Sendable, Equatable {
        case fit
        case fill
    }

    static func contentRect(imageSize: CGSize, in viewSize: CGSize, mode: Mode) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        let width: CGFloat
        let height: CGFloat
        switch mode {
        case .fit:
            if imageAspect > viewAspect {
                width = viewSize.width
                height = width / imageAspect
            } else {
                height = viewSize.height
                width = height * imageAspect
            }
        case .fill:
            if imageAspect > viewAspect {
                height = viewSize.height
                width = height * imageAspect
            } else {
                width = viewSize.width
                height = width / imageAspect
            }
        }
        return CGRect(
            x: (viewSize.width - width) / 2,
            y: (viewSize.height - height) / 2,
            width: width,
            height: height)
    }

    /// Maps a view point into Quartz global display coordinates.
    /// - Parameter clampToContent: when true (pointer move), letterbox taps ride the
    ///   content edge like Vamp's `GestureInterpreter.drag`. When false (clicks),
    ///   out-of-content taps return nil so random letterbox clicks are ignored.
    static func mapPoint(
        _ location: CGPoint,
        contentRect: CGRect,
        displayX: Double,
        displayY: Double,
        displayWidth: Double,
        displayHeight: Double,
        clampToContent: Bool = false
    ) -> CGPoint? {
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        let clamped = CGPoint(
            x: min(max(location.x, contentRect.minX), contentRect.maxX),
            y: min(max(location.y, contentRect.minY), contentRect.maxY)
        )
        if !clampToContent {
            guard location.x >= contentRect.minX, location.x <= contentRect.maxX,
                  location.y >= contentRect.minY, location.y <= contentRect.maxY else {
                return nil
            }
        }
        let nx = (clamped.x - contentRect.minX) / contentRect.width
        let ny = (clamped.y - contentRect.minY) / contentRect.height
        return CGPoint(
            x: displayX + Double(nx) * displayWidth,
            y: displayY + Double(ny) * displayHeight)
    }

    /// Scales finger deltas so a phone-sized trackpad covers the Mac desktop the way
    /// Vamp's `viewDeltaToDisplayDelta` does.
    static func scaleRelativeDelta(
        dx: Double,
        dy: Double,
        displayWidth: Double,
        displayHeight: Double,
        surfaceWidth: Double,
        surfaceHeight: Double,
        sensitivity: Double = 2.0
    ) -> (dx: Double, dy: Double) {
        let widthScale = displayWidth / max(surfaceWidth, 1)
        let heightScale = displayHeight / max(surfaceHeight, 1)
        let scale = max(widthScale, heightScale) * sensitivity
        return (dx * scale, dy * scale)
    }

    /// Vamp `DisplayMappingEngine.viewDeltaToDisplayDelta` for scroll / relative gestures.
    static func scaleViewDeltaToDisplay(
        dx: Double,
        dy: Double,
        contentWidth: Double,
        contentHeight: Double,
        displayWidth: Double,
        displayHeight: Double
    ) -> (dx: Double, dy: Double) {
        guard contentWidth > 0, contentHeight > 0 else { return (dx, dy) }
        return (
            dx * (displayWidth / contentWidth),
            dy * (displayHeight / contentHeight)
        )
    }

    /// Vamp `RemoteInteractionViewModel.accelerated`: `1.0 + min(speed / 50, 1.5)`.
    static func accelerated(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        let speed = hypot(dx, dy)
        let factor = 1.0 + min(speed / 50.0, 1.5)
        return (dx * factor, dy * factor)
    }
}
