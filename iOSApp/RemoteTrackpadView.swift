import SwiftUI
import UIKit

/// Relative trackpad: 1-finger move, tap/double/right/middle click, 2-finger scroll, long-press drag-lock.
struct RemoteTrackpadView: View {
    var onMove: (Double, Double) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var onRightClick: () -> Void
    var onMiddleClick: () -> Void
    var onScroll: (Double, Double) -> Void
    var onDragLockToggle: () -> Void

    @State private var isTouching = false
    @State private var pulse = false

    private static let accent = Color(white: 0.72)
    private static let surface = Color(white: 0.07)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Self.surface)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    isTouching ? Self.accent.opacity(0.45) : Color.white.opacity(0.07),
                    lineWidth: isTouching ? 1.4 : 1)

            Circle()
                .fill(Self.accent.opacity(0.18))
                .frame(width: pulse ? 84 : 60, height: pulse ? 84 : 60)
                .blur(radius: 18)
            Circle()
                .fill(Self.accent)
                .frame(width: 18, height: 18)
                .shadow(color: Self.accent.opacity(0.9), radius: pulse ? 22 : 9)
                .scaleEffect(pulse ? 1.3 : 0.9)
                .opacity(isTouching ? 1 : 0.9)

            VStack {
                Spacer()
                Text("trackpad")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
                    .padding(.bottom, 14)
            }

            TrackpadGestureSurface(
                onMove: onMove,
                onClick: onClick,
                onDoubleClick: onDoubleClick,
                onRightClick: onRightClick,
                onMiddleClick: onMiddleClick,
                onScroll: onScroll,
                onDragLockToggle: onDragLockToggle,
                onTouchActive: { isTouching = $0 }
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Vamp Control–faithful fullscreen gesture surface (no trackpad UI):
/// 1-finger = absolute pointer move · tap = click · long-press = drag-lock ·
/// pinch = zoom · 2-finger = scroll (or viewport pan when zoomed) · hover = relative.
struct RemoteScreenGestureSurface: UIViewRepresentable {
    var zoom: CGFloat
    var offset: CGSize
    var viewSize: CGSize
    var onTap: (CGPoint) -> Void
    var onDoubleTap: (CGPoint) -> Void
    var onRightClick: (CGPoint) -> Void
    var onMiddleClick: (CGPoint) -> Void
    /// Absolute pointer move only — never auto mouse-down (Vamp pattern).
    var onPointerMove: (CGPoint) -> Void
    var onPointerEnded: () -> Void
    var onScroll: (Double, Double) -> Void
    var onViewportPan: (CGSize) -> Void
    var onPinchChanged: (CGFloat, CGPoint) -> Void
    var onPinchEnded: () -> Void
    var onLongPress: (CGPoint) -> Void
    var onHoverDelta: (Double, Double) -> Void = { _, _ in }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.zoom = zoom
        context.coordinator.offset = offset
        context.coordinator.viewSize = viewSize
        context.coordinator.callbacks = makeCallbacks()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(makeCallbacks()) }

    private func makeCallbacks() -> Coordinator.Callbacks {
        Coordinator.Callbacks(
            onTap: onTap,
            onDoubleTap: onDoubleTap,
            onRightClick: onRightClick,
            onMiddleClick: onMiddleClick,
            onPointerMove: onPointerMove,
            onPointerEnded: onPointerEnded,
            onScroll: onScroll,
            onViewportPan: onViewportPan,
            onPinchChanged: onPinchChanged,
            onPinchEnded: onPinchEnded,
            onLongPress: onLongPress,
            onHoverDelta: onHoverDelta)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        struct Callbacks {
            var onTap: (CGPoint) -> Void
            var onDoubleTap: (CGPoint) -> Void
            var onRightClick: (CGPoint) -> Void
            var onMiddleClick: (CGPoint) -> Void
            var onPointerMove: (CGPoint) -> Void
            var onPointerEnded: () -> Void
            var onScroll: (Double, Double) -> Void
            var onViewportPan: (CGSize) -> Void
            var onPinchChanged: (CGFloat, CGPoint) -> Void
            var onPinchEnded: () -> Void
            var onLongPress: (CGPoint) -> Void
            var onHoverDelta: (Double, Double) -> Void
        }

        var callbacks: Callbacks
        var zoom: CGFloat = 1
        var offset: CGSize = .zero
        var viewSize: CGSize = .zero

        private weak var pinchRecognizer: UIPinchGestureRecognizer?
        private weak var twoFingerPanRecognizer: UIPanGestureRecognizer?
        private var lastOneFingerTranslation: CGSize = .zero
        private var lastTwoFingerTranslation: CGSize = .zero
        private var twoFingerPansViewport = false
        private var scrollVelocity: CGSize = .zero
        private var momentumLink: CADisplayLink?
        private var lastHoverLocation: CGPoint?

        init(_ callbacks: Callbacks) { self.callbacks = callbacks }

        func attach(to view: UIView) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.require(toFail: doubleTap)
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
            threeFingerTap.numberOfTouchesRequired = 3

            // Standard pan — Vamp Gestures uses UIPanGestureRecognizer (not immediate).
            let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
            oneFingerPan.maximumNumberOfTouches = 1
            oneFingerPan.cancelsTouchesInView = false
            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPanRecognizer = twoFingerPan

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinchRecognizer = pinch

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            longPress.minimumPressDuration = 0.5

            let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))

            for recognizer in [singleTap, doubleTap, twoFingerTap, threeFingerTap, oneFingerPan, twoFingerPan, pinch, longPress, hover] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        func detach(from view: UIView) {
            cancelMomentum()
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.delegate = nil
                view.removeGestureRecognizer(recognizer)
            }
        }

        /// Undo video scaleEffect/offset so taps map to the untransformed content rect.
        /// Matches Vamp `MirrorFullscreenGestureView.adjustedPoint` (no fingertip offset).
        private func adjustedPoint(_ point: CGPoint) -> CGPoint {
            guard zoom != 1 || offset != .zero else { return point }
            let centerX = viewSize.width / 2
            let centerY = viewSize.height / 2
            return CGPoint(
                x: centerX + (point.x - centerX - offset.width) / zoom,
                y: centerY + (point.y - centerY - offset.height) / zoom)
        }

        private var isPinching: Bool {
            guard let pinchRecognizer else { return false }
            return pinchRecognizer.state == .began || pinchRecognizer.state == .changed
        }

        @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            cancelMomentum()
            callbacks.onTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            callbacks.onDoubleTap(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            callbacks.onRightClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            callbacks.onMiddleClick(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleOneFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                // Vamp: do not warp the cursor on touch-down — only track after movement.
                cancelMomentum()
                lastOneFingerTranslation = .zero
            case .changed:
                let translation = recognizer.translation(in: view)
                lastOneFingerTranslation = CGSize(width: translation.x, height: translation.y)
                // Absolute map of the zoom-adjusted touch — same as Vamp `onDragChanged`.
                callbacks.onPointerMove(adjustedPoint(recognizer.location(in: view)))
            case .ended, .cancelled, .failed:
                lastOneFingerTranslation = .zero
                callbacks.onPointerEnded()
            default:
                break
            }
        }

        @objc private func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                cancelMomentum()
                lastTwoFingerTranslation = .zero
                scrollVelocity = .zero
                // Latch pan-vs-scroll at start so a concurrent pinch can't flip mid-gesture.
                twoFingerPansViewport = zoom > 1.05 || isPinching
            case .changed:
                let translation = recognizer.translation(in: view)
                let deltaX = translation.x - lastTwoFingerTranslation.width
                let deltaY = translation.y - lastTwoFingerTranslation.height
                lastTwoFingerTranslation = CGSize(width: translation.x, height: translation.y)

                if isPinching { twoFingerPansViewport = true }
                if twoFingerPansViewport {
                    callbacks.onViewportPan(CGSize(width: deltaX, height: deltaY))
                } else {
                    let sx = Double(-deltaX)
                    let sy = Double(deltaY)
                    callbacks.onScroll(sx, sy)
                    scrollVelocity = CGSize(width: sx, height: sy)
                }
            case .ended:
                lastTwoFingerTranslation = .zero
                if !twoFingerPansViewport { startMomentum() }
            case .cancelled, .failed:
                lastTwoFingerTranslation = .zero
            default:
                break
            }
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                cancelMomentum()
                twoFingerPansViewport = true
            case .changed:
                guard let view = recognizer.view else { return }
                callbacks.onPinchChanged(recognizer.scale, recognizer.location(in: view))
                recognizer.scale = 1
            case .ended, .cancelled:
                callbacks.onPinchEnded()
            default:
                break
            }
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let view = recognizer.view else { return }
            callbacks.onLongPress(adjustedPoint(recognizer.location(in: view)))
        }

        @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                lastHoverLocation = location
            case .changed:
                guard let last = lastHoverLocation else {
                    lastHoverLocation = location
                    return
                }
                let dx = location.x - last.x
                let dy = location.y - last.y
                lastHoverLocation = location
                if dx != 0 || dy != 0 {
                    callbacks.onHoverDelta(Double(dx), Double(dy))
                }
            case .ended, .cancelled, .failed:
                lastHoverLocation = nil
            default:
                break
            }
        }

        private func startMomentum() {
            let speed = hypot(scrollVelocity.width, scrollVelocity.height)
            guard speed > 1.5 else { return }
            momentumLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(momentumTick))
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        private func cancelMomentum() {
            momentumLink?.invalidate()
            momentumLink = nil
            scrollVelocity = .zero
        }

        @objc private func momentumTick() {
            callbacks.onScroll(Double(scrollVelocity.width), Double(scrollVelocity.height))
            scrollVelocity = CGSize(width: scrollVelocity.width * 0.92, height: scrollVelocity.height * 0.92)
            if hypot(scrollVelocity.width, scrollVelocity.height) < 0.4 {
                cancelMomentum()
            }
        }

        /// Vamp rule: only pinch may run with two-finger pan. Everything else is exclusive
        /// so taps don't fire during pans (the main source of random clicks).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer is UIHoverGestureRecognizer || other is UIHoverGestureRecognizer {
                return true
            }
            let isPinch = gestureRecognizer is UIPinchGestureRecognizer
            let otherIsPinch = other is UIPinchGestureRecognizer
            let isTwoFingerPan = (gestureRecognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            let otherIsTwoFingerPan = (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            return (isPinch && otherIsTwoFingerPan) || (otherIsPinch && isTwoFingerPan)
        }
    }
}

private struct TrackpadGestureSurface: UIViewRepresentable {
    var onMove: (Double, Double) -> Void
    var onClick: () -> Void
    var onDoubleClick: () -> Void
    var onRightClick: () -> Void
    var onMiddleClick: () -> Void
    var onScroll: (Double, Double) -> Void
    var onDragLockToggle: () -> Void
    var onTouchActive: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        view.isMultipleTouchEnabled = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.callbacks = makeCallbacks()
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(makeCallbacks()) }

    private func makeCallbacks() -> Coordinator.Callbacks {
        Coordinator.Callbacks(
            onMove: onMove, onClick: onClick, onDoubleClick: onDoubleClick,
            onRightClick: onRightClick, onMiddleClick: onMiddleClick, onScroll: onScroll,
            onDragLockToggle: onDragLockToggle, onTouchActive: onTouchActive)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        struct Callbacks {
            var onMove: (Double, Double) -> Void
            var onClick: () -> Void
            var onDoubleClick: () -> Void
            var onRightClick: () -> Void
            var onMiddleClick: () -> Void
            var onScroll: (Double, Double) -> Void
            var onDragLockToggle: () -> Void
            var onTouchActive: (Bool) -> Void
        }

        var callbacks: Callbacks
        private var lastPan: CGPoint = .zero
        private var lastTwoFinger: CGPoint = .zero
        private var lastPanTime: TimeInterval = 0
        private var pointerCurve = RemotePointerCurve()

        init(_ callbacks: Callbacks) { self.callbacks = callbacks }

        func attach(to view: UIView) {
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            singleTap.require(toFail: doubleTap)
            let two = UITapGestureRecognizer(target: self, action: #selector(twoFinger(_:)))
            two.numberOfTouchesRequired = 2
            let three = UITapGestureRecognizer(target: self, action: #selector(threeFinger(_:)))
            three.numberOfTouchesRequired = 3
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            pan.maximumNumberOfTouches = 1
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
            hold.minimumPressDuration = 0.5
            for recognizer in [singleTap, doubleTap, two, three, pan, scroll, hold] {
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
        }

        func detach(from view: UIView) {
            for recognizer in view.gestureRecognizers ?? [] {
                recognizer.delegate = nil
                view.removeGestureRecognizer(recognizer)
            }
        }

        @objc private func tap(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onClick() }
        }
        @objc private func doubleTap(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onDoubleClick() }
        }
        @objc private func twoFinger(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onRightClick() }
        }
        @objc private func threeFinger(_ g: UITapGestureRecognizer) {
            if g.state == .ended { callbacks.onMiddleClick() }
        }
        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began:
                lastPan = g.translation(in: view)
                lastPanTime = ProcessInfo.processInfo.systemUptime
                pointerCurve.reset()
                callbacks.onTouchActive(true)
            case .changed:
                let now = ProcessInfo.processInfo.systemUptime
                let t = g.translation(in: view)
                let deltaX = Double(t.x - lastPan.x)
                let deltaY = Double(t.y - lastPan.y)
                let output = pointerCurve.apply(dx: deltaX, dy: deltaY, elapsed: now - lastPanTime)
                callbacks.onMove(output.dx, output.dy)
                lastPan = t
                lastPanTime = now
            case .ended, .cancelled, .failed:
                pointerCurve.reset()
                lastPanTime = 0
                callbacks.onTouchActive(false)
            default: break
            }
        }
        @objc private func scroll(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            switch g.state {
            case .began: lastTwoFinger = g.translation(in: view)
            case .changed:
                let t = g.translation(in: view)
                callbacks.onScroll(Double(-(t.x - lastTwoFinger.x)), Double(t.y - lastTwoFinger.y))
                lastTwoFinger = t
            default: break
            }
        }
        @objc private func hold(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { callbacks.onDragLockToggle() }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            false
        }
    }
}
