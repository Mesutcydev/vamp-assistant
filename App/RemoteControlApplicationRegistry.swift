import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// The Vamp Assistant HTTP projection of the same app registry used by Vamp Stream's
/// Vamp Host transport: running applications first, then installed applications from
/// the standard macOS app directories. Bundle identifiers are stable across refreshes.
@MainActor
final class RemoteControlApplicationRegistry {
    struct Application: Equatable {
        let bundleIdentifier: String
        let name: String
        let isRunning: Bool
        let isActive: Bool
        let iconPNGBase64: String?
        let windowID: UInt32?
        let windowTitle: String?
        let width: Double
        let height: Double
    }

    enum RegistryError: LocalizedError {
        case applicationUnavailable
        case applicationDidNotOpenWindow
        case accessibilityRequired
        case invalidViewportAspect
        case windowUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationUnavailable:
                "That application is no longer installed on the Mac."
            case .applicationDidNotOpenWindow:
                "The application opened but did not create a streamable window."
            case .accessibilityRequired:
                "Accessibility permission is required to resize a streamed application."
            case .invalidViewportAspect:
                "The client viewport aspect ratio is invalid."
            case .windowUnavailable:
                "That application window is no longer available."
            }
        }
    }

    private struct Window {
        let id: UInt32
        let ownerPID: pid_t
        let title: String?
        let bounds: CGRect

        var area: Double { bounds.width * bounds.height }
    }

    private var iconCache: [String: String] = [:]

    func snapshot(includeIcons: Bool = true) -> [Application] {
        let windowsByPID = Dictionary(grouping: onScreenWindows(), by: \.ownerPID)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let selfBundleID = Bundle.main.bundleIdentifier
        var runningApplications: [Application] = []
        var runningBundleIdentifiers: Set<String> = []

        for running in NSWorkspace.shared.runningApplications {
            guard running.activationPolicy == .regular,
                  let bundleIdentifier = running.bundleIdentifier,
                  bundleIdentifier != selfBundleID,
                  let name = running.localizedName else { continue }
            let isActive = running.processIdentifier == frontmostPID
            let icon = includeIcons
                ? iconBase64(bundleIdentifier: bundleIdentifier, icon: running.icon)
                : nil
            let windows = Self.streamableWindows(
                windowsByPID[running.processIdentifier] ?? [])

            // A running app with no on-screen layer-0 window stays visible as a
            // launchable/activatable row. Apps with one or more windows expose each
            // window independently, matching Sync's window-aware inventory instead
            // of silently hiding every non-largest window.
            if windows.isEmpty {
                runningApplications.append(Application(
                    bundleIdentifier: bundleIdentifier,
                    name: name,
                    isRunning: false,
                    isActive: isActive,
                    iconPNGBase64: icon,
                    windowID: nil,
                    windowTitle: nil,
                    width: 0,
                    height: 0))
            } else {
                for window in windows {
                    runningApplications.append(Application(
                        bundleIdentifier: bundleIdentifier,
                        name: name,
                        isRunning: true,
                        isActive: isActive,
                        iconPNGBase64: icon,
                        windowID: window.id,
                        windowTitle: window.title,
                        width: Double(window.bounds.width),
                        height: Double(window.bounds.height)))
                }
            }
            runningBundleIdentifiers.insert(bundleIdentifier)
        }

        for url in Self.installedApplicationURLs() {
            guard let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                  bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true,
                  bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                  bundleIdentifier != selfBundleID,
                  !runningBundleIdentifiers.contains(bundleIdentifier) else { continue }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            runningApplications.append(Application(
                bundleIdentifier: bundleIdentifier,
                name: name,
                isRunning: false,
                isActive: false,
                iconPNGBase64: includeIcons
                    ? iconBase64(
                        bundleIdentifier: bundleIdentifier,
                        icon: NSWorkspace.shared.icon(forFile: url.path))
                    : nil,
                windowID: nil,
                windowTitle: nil,
                width: 0,
                height: 0))
        }

        return runningApplications.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func streamableWindows(_ windows: [Window]) -> [Window] {
        windows.sorted { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            return lhs.id < rhs.id
        }
    }

    func launch(bundleIdentifier: String, clientViewportAspect: Double? = nil) async throws -> Application {
        if let clientViewportAspect {
            try Self.validate(aspect: clientViewportAspect)
        }
        guard let url = ApplicationLaunchResolver.resolveLaunchURL(
            appName: nil, bundleID: bundleIdentifier)
        else { throw RegistryError.applicationUnavailable }
        let preferred = url.standardizedFileURL
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.bundleURL?.standardizedFileURL == preferred }) {
            running.activate(options: [.activateAllWindows])
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: preferred, configuration: configuration)
        }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
            guard let runningURL = running.bundleURL?.standardizedFileURL,
                  runningURL != preferred,
                  ApplicationLaunchResolver.isBackupAppName(
                    runningURL.deletingPathExtension().lastPathComponent)
            else { continue }
            running.terminate()
        }

        var requestedNewWindow = false
        for attempt in 0..<40 {
            if let application = snapshot(includeIcons: true).first(where: {
                $0.bundleIdentifier == bundleIdentifier && $0.windowID != nil
            }), let windowID = application.windowID,
               await Self.isShareableWindow(windowID) {
                guard let clientViewportAspect else { return application }
                guard let running = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier
                ).first else { throw RegistryError.applicationUnavailable }
                // Launch must still succeed when Accessibility has not been granted or an app
                // enforces a minimum window size. The explicit resize route reports that state;
                // launch returns the closest streamable geometry.
                try? resizeFocusedWindow(
                    pid: running.processIdentifier,
                    toAspect: clientViewportAspect,
                    preferredBounds: nil)
                try await Task.sleep(for: .milliseconds(350))
                // Report the window that was just fitted. Re-querying by bundle identifier
                // returns the app's *largest* window, which after a fit is very likely a
                // different one than the fit touched.
                return self.application(forWindowID: windowID, includeIcons: true) ?? application
            }
            // Safari and several document apps can remain running with every
            // window closed. Activating that process does not create a window,
            // so the old launch path timed out with “no streamable window”.
            // Request a real document/window early, then continue waiting for an
            // actual layer-0 window before returning it to the phone.
            if attempt == 4,
               !requestedNewWindow,
               let running = NSRunningApplication.runningApplications(
                    withBundleIdentifier: bundleIdentifier).first {
                requestedNewWindow = true
                await requestNewWindow(for: bundleIdentifier, running: running)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw RegistryError.applicationDidNotOpenWindow
    }

    /// Ask an already-running app to materialize a streamable window. Safari
    /// accepts an open-document event without Accessibility permission; this is
    /// important because app streaming only requires Screen Recording. Other
    /// apps keep the original Cmd-N path when Accessibility is available.
    private func requestNewWindow(for bundleIdentifier: String, running: NSRunningApplication) async {
        running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        if bundleIdentifier == "com.apple.Safari",
           let applicationURL = running.bundleURL,
           let blankURL = URL(string: "about:blank") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [blankURL],
                withApplicationAt: applicationURL,
                configuration: configuration,
                completionHandler: nil)
            return
        }

        guard ComputerPermission.accessibilityGranted else { return }
        try? await RemoteMacControl.perform(.key("n", modifiers: ["command"]))
    }

    func resize(windowID: UInt32, clientViewportAspect: Double) async throws -> Application {
        try Self.validate(aspect: clientViewportAspect)
        guard let window = onScreenWindows().first(where: { $0.id == windowID }) else {
            throw RegistryError.windowUnavailable
        }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == window.ownerPID
        }), running.bundleIdentifier != nil else {
            throw RegistryError.windowUnavailable
        }
        running.activate()
        try resizeFocusedWindow(
            pid: window.ownerPID,
            toAspect: clientViewportAspect,
            preferredBounds: window.bounds,
            windowID: windowID)
        try await Task.sleep(for: .milliseconds(350))
        // Same window in, same window out — resizing never changes a CGWindowID, and looking
        // it back up by bundle identifier would hand back the app's largest window instead.
        guard let application = self.application(forWindowID: windowID, includeIcons: true) else {
            throw RegistryError.windowUnavailable
        }
        return application
    }

    /// The Accessibility element for the window at `bounds`. A nil `bounds` means
    /// the caller named no window (the launch path, where no bounds are known
    /// yet) and the app's focused window is the only sensible answer.
    ///
    /// AX exposes no public window-number attribute, so the on-screen frame is the join key
    /// back to the `CGWindowID` the client asked about. `kAXFocusedWindowAttribute` alone was
    /// not the same window: `resize(windowID:)` names one window, and an app with several
    /// windows can easily have focus on a different one — the fit then reshaped a window
    /// nobody was streaming. AXPosition and kCGWindowBounds are both global, points, top-left.
    ///
    /// When bounds *are* supplied the match must be unique. Matching on origin alone, and then
    /// silently falling back to the focused window, meant a stale or ambiguous frame reshaped
    /// a window the client never named. Refusing is the honest answer: the caller reports that
    /// this window could not be resized instead of moving an unrelated one.
    nonisolated private static func axWindow(pid: pid_t, matching bounds: CGRect?) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var windows: [AXUIElement] = []
        var windowsReference: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsReference
        ) == .success, let listed = windowsReference as? [AXUIElement] {
            windows = listed
        }

        if let bounds {
            let frames = windows.map(frame(of:))
            guard let index = uniqueWindowIndex(matching: bounds, among: frames) else {
                return nil
            }
            return windows[index]
        }

        if let index = windows.firstIndex(where: { isFocusedWindow($0, of: application) }) {
            return windows[index]
        }
        var focusedReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedReference
        ) == .success,
        let focusedReference,
        CFGetTypeID(focusedReference) == AXUIElementGetTypeID() else { return nil }
        return (focusedReference as! AXUIElement)
    }

    /// The index of the one window whose frame matches `bounds` on origin **and** size.
    ///
    /// Returns nil for no match and — deliberately — for more than one. Two windows of the same
    /// app at the same origin is exactly the case where resizing the wrong one is invisible to
    /// the user until the phone shows the wrong window.
    nonisolated static func uniqueWindowIndex(
        matching bounds: CGRect,
        among frames: [CGRect],
        tolerance: CGFloat = 2
    ) -> Int? {
        let matches = frames.indices.filter { index in
            let frame = frames[index]
            return abs(frame.origin.x - bounds.origin.x) <= tolerance
                && abs(frame.origin.y - bounds.origin.y) <= tolerance
                && abs(frame.width - bounds.width) <= tolerance
                && abs(frame.height - bounds.height) <= tolerance
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The on-screen frame of a window element, or nil when AX will not report one.
    nonisolated private static func frame(of window: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero
        var positionReference: CFTypeRef?
        var sizeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionReference
        ) == .success,
        let positionReference,
        CFGetTypeID(positionReference) == AXValueGetTypeID(),
        AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeReference
        ) == .success,
        let sizeReference,
        CFGetTypeID(sizeReference) == AXValueGetTypeID() else { return .zero }
        AXValueGetValue(positionReference as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeReference as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    nonisolated private static func isFocusedWindow(
        _ window: AXUIElement,
        of application: AXUIElement
    ) -> Bool {
        var focusedReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedReference
        ) == .success,
        let focusedReference,
        CFGetTypeID(focusedReference) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focusedReference as! AXUIElement, window)
    }

    /// The registry entry for one specific window, rather than for the app's largest one.
    ///
    /// `snapshot()` reports `bestWindow` — the biggest window an app owns — which stopped being
    /// the right answer once fitting deliberately shrinks the streamed window: the fit lands on
    /// one window and the reported `windowID` comes back pointing at a different, now-bigger
    /// one. The client then streams a window that was never fitted, and a `windowID` that
    /// changes between calls restarts the stream each time. The caller named a window; answer
    /// about that window.
    private func application(forWindowID windowID: UInt32, includeIcons: Bool) -> Application? {
        guard let window = onScreenWindows().first(where: { $0.id == windowID }) else { return nil }
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier == window.ownerPID
        }), let bundleIdentifier = running.bundleIdentifier, let name = running.localizedName else {
            return nil
        }
        return Application(
            bundleIdentifier: bundleIdentifier,
            name: name,
            isRunning: true,
            isActive: running.processIdentifier
                == NSWorkspace.shared.frontmostApplication?.processIdentifier,
            iconPNGBase64: includeIcons
                ? iconBase64(bundleIdentifier: bundleIdentifier, icon: running.icon)
                : nil,
            windowID: window.id,
            windowTitle: window.title,
            width: Double(window.bounds.width),
            height: Double(window.bounds.height))
    }

    private static func validate(aspect: Double) throws {
        guard aspect.isFinite, (0.25...4).contains(aspect) else {
            throw RegistryError.invalidViewportAspect
        }
    }

    /// Where a window of `size` should be anchored: its current origin when that still fits on
    /// the display, otherwise pushed inside the usable area.
    ///
    /// Computed from the **requested** size, never from a freshly-read AX frame. An AX size set
    /// is applied asynchronously, so an immediate read still returns the old frame — which is how
    /// a window low on the display ended up clamped to the room below its *old* origin, keeping a
    /// different shape than the requested aspect and capturing smaller than the phone renders.
    nonisolated static func anchoredOrigin(
        requestedSize size: CGSize,
        currentOrigin: CGPoint,
        display: CGRect
    ) -> CGPoint {
        let available = Self.usableArea(display)
        let x = max(available.minX,
                    min(currentOrigin.x, max(available.maxX - size.width, available.minX)))
        let y = max(available.minY,
                    min(currentOrigin.y, max(available.maxY - size.height, available.minY)))
        return CGPoint(x: x, y: y)
    }

    /// The display minus the menu bar and a small margin, so a fitted window is never flush to a
    /// screen edge or tucked under the menu bar.
    nonisolated private static func usableArea(_ display: CGRect) -> CGRect {
        CGRect(
            x: display.minX + 24,
            y: display.minY + 52,
            width: max(display.width - 48, 1),
            height: max(display.height - 76, 1))
    }

    /// Position, then size, then re-assert the position.
    ///
    /// AppKit constrains a window's frame to the screen when its size is applied, so sizing a
    /// window that sits low on the display silently clamps its height to whatever fit below the
    /// *old* origin. Moving first — to an anchor derived from the requested size — gives the size
    /// set room to be honoured; re-applying the anchor afterwards keeps the window there, because
    /// growing can shift the origin. Mirrors `HostSessionCoordinator.resizeWindow`.
    nonisolated private static func applyFrame(
        to window: AXUIElement,
        origin: CGPoint,
        size: CGSize
    ) {
        var requestedOrigin = origin
        let positionValue = AXValueCreate(.cgPoint, &requestedOrigin)
        if let positionValue {
            _ = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue)
        }
        var requestedSize = size
        if let sizeValue = AXValueCreate(.cgSize, &requestedSize) {
            _ = AXUIElementSetAttributeValue(
                window,
                kAXSizeAttribute as CFString,
                sizeValue)
        }
        if let positionValue {
            _ = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue)
        }
    }

    private func resizeFocusedWindow(
        pid: pid_t,
        toAspect aspect: Double,
        preferredBounds: CGRect?,
        windowID: UInt32? = nil
    ) throws {
        guard AXIsProcessTrusted() else { throw RegistryError.accessibilityRequired }
        guard let window = Self.axWindow(pid: pid, matching: preferredBounds) else {
            throw RegistryError.windowUnavailable
        }

        let before = Self.frame(of: window)
        let currentBounds = before == .zero ? (preferredBounds ?? .zero) : before
        let displayBounds = Self.displayBounds(containing: currentBounds)
        let targetFrame = Self.targetWindowFrame(
            current: currentBounds,
            display: displayBounds,
            aspect: CGFloat(aspect))
        let requestedSize = targetFrame.size
        let requestedOrigin = Self.anchoredOrigin(
            requestedSize: requestedSize,
            currentOrigin: currentBounds.origin,
            display: displayBounds)

        var retried = false
        var observed = before
        // Two passes at most. The first is the fix; the second is idempotent and covers an app
        // whose AX size set landed before the move settled.
        //
        // The retry keys on **aspect**, not on the size matching exactly. An app that constrains
        // its first AX resize — before accepting the new origin, or while it relayouts — leaves a
        // window that kept its own shape, and shape is what the phone actually renders: a window
        // that is 3pt off its request is fine, a window at the wrong aspect is letterboxed. A
        // size set can still report failure for a window enforcing a minimum, or one that is
        // simply fixed — that is the app declining, not a window that has gone away, so the
        // request never fails here. The snapshot in `resize(windowID:)` stays authoritative.
        for attempt in 0..<2 {
            Self.applyFrame(to: window, origin: requestedOrigin, size: requestedSize)
            observed = Self.frame(of: window)
            let mismatched = Self.aspectMismatch(observed.size, desired: requestedSize)
            if !mismatched { break }
            retried = attempt == 0
        }

        // Durability matters: a live "the Mac kept a different window shape" report has to be
        // diagnosable from the host's ordinary log, without a special build. `.notice` survives
        // the default in-memory level, and the payload is geometry only — never a title, never
        // window content.
        let requested = "\(Int(requestedSize.width))x\(Int(requestedSize.height))"
            + "@\(Int(requestedOrigin.x)),\(Int(requestedOrigin.y))"
        let seen = "\(Int(observed.width))x\(Int(observed.height))"
            + "@\(Int(observed.origin.x)),\(Int(observed.origin.y))"
        Log.app.notice(
            "window resize requested=\(requested, privacy: .public) observed=\(seen, privacy: .public) aspect=\(aspect, privacy: .public) windowID=\(windowID.map(String.init) ?? "launch", privacy: .public) retried=\(retried, privacy: .public)"
        )
    }

    /// The longest edge a fitted window may reach, in points.
    ///
    /// The client is an iPhone 17 Pro Max at 1320×2868 px, so a 2× Mac needs 1434 points to hand
    /// it native pixels; 1440 points is 2880 px — just over that, while still inside the decoder
    /// envelope. Without the cap a 5K/6K display would produce a capture taller than the client's
    /// hardware decoder accepts. Mirrors `AdaptiveWindowSizing.maxEdgePoints` in the Sync host.
    nonisolated static let maxEdgePoints: CGFloat = 1440

    /// The largest window matching the phone viewport that still fits the Mac display.
    ///
    /// Two corrections over the previous shrink-only fit, both ported from the Sync host's
    /// `AdaptiveWindowSizing` so the two providers shape a streamed window identically:
    ///
    /// 1. **Fit into the display rather than shrinking to the source.** Shrink-only turned a
    ///    small source window (Terminal's default is about 528×374) into roughly 172×374, which
    ///    the phone then upscaled ~3× — giant text and ~31 columns. The matched shape is now
    ///    scaled *up* to fill the available space, so the same source yields a full-size window.
    /// 2. **Cap the longest edge** so a 5K-class display cannot produce a capture taller than the
    ///    client's hardware decoder accepts.
    ///
    /// Sizing is deliberately app-agnostic. A per-app width exception would put the window's
    /// aspect above the viewport's, and an aspect-fit renderer shrinks that into a horizontal
    /// strip with black bars — the letterbox this whole path exists to remove.
    nonisolated static func targetWindowFrame(
        current: CGRect,
        display: CGRect,
        aspect: CGFloat
    ) -> CGRect {
        guard aspect.isFinite, aspect > 0 else { return current }
        let available = CGRect(
            x: display.minX + 24,
            y: display.minY + 52,
            width: max(display.width - 48, 1),
            height: max(display.height - 76, 1))
        let clampedAspect = min(max(aspect, 0.25), 4)
        // Clamp first so the aspect match starts from a shape the display can actually hold.
        let currentSize = CGSize(
            width: min(max(current.width, 1), available.width),
            height: min(max(current.height, 1), available.height))
        // Match the viewport aspect by holding the **width** and deriving the height.
        //
        // Holding the shorter dimension instead (the previous behaviour) asked for a narrow
        // window: from a 640x480 source and a portrait viewport it requested 220x480. An app with
        // a minimum window width — Safari's floor is 574pt — cannot accept that, so it stayed
        // 574x480. The aspect then came back 1.196 against the phone's 0.461, which is precisely
        // the "The Mac kept a different window shape" letterbox. Deriving the height from the
        // current width keeps the request inside what the app will accept, and the fit below has
        // already bounded it by the display, so the window still cannot grow off-screen.
        let matchedWidth = currentSize.width
        let matchedHeight = currentSize.width / clampedAspect
        // Then scale that shape *into* the display instead of leaving it small, bounded by the
        // decoder-friendly longest edge.
        let fitScale = min(
            min(available.width / matchedWidth, available.height / matchedHeight),
            maxEdgePoints / max(matchedWidth, matchedHeight))
        var size = CGSize(
            width: max(1, floor(matchedWidth * fitScale)),
            height: max(1, floor(matchedHeight * fitScale)))
        // Never fit below what `onScreenWindows()` will still report as a window (80 x 60).
        // A portrait viewport sets width to height x ~0.46, so a window under ~173pt tall fitted
        // to under 80pt wide and vanished from discovery entirely — taking the stream target
        // with it. Exact aspect is worth trading for a window that still exists.
        size.width = min(max(size.width, 96), available.width)
        size.height = min(max(size.height, 72), available.height)
        let maxX = max(available.minX, available.maxX - size.width)
        let maxY = max(available.minY, available.maxY - size.height)
        return CGRect(
            x: min(max(current.minX, available.minX), maxX),
            y: min(max(current.minY, available.minY), maxY),
            width: size.width,
            height: size.height)
    }

    /// Whether an accepted window frame still disagrees with the requested shape by more than
    /// `tolerance` of aspect. Pure, and shared by the retry decision and the user-visible
    /// notice, so "we retried" and "we told the user" can never disagree — the Sync host's
    /// `aspectMismatch`, used identically.
    nonisolated static func aspectMismatch(
        _ accepted: CGSize,
        desired: CGSize,
        tolerance: CGFloat = 0.05
    ) -> Bool {
        guard accepted.width.isFinite, accepted.height.isFinite, accepted.width > 0,
              accepted.height > 0,
              desired.width.isFinite, desired.height.isFinite, desired.width > 0,
              desired.height > 0 else { return false }
        let acceptedAspect = accepted.width / accepted.height
        let desiredAspect = desired.width / desired.height
        return abs(acceptedAspect - desiredAspect) > tolerance
    }

    nonisolated private static func displayBounds(containing window: CGRect) -> CGRect {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        return displays.prefix(Int(count))
            .map(CGDisplayBounds)
            .max { lhs, rhs in
                lhs.intersection(window).area < rhs.intersection(window).area
            } ?? CGDisplayBounds(CGMainDisplayID())
    }

    private func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let idNumber = entry[kCGWindowNumber as String] as? NSNumber,
                  let layerNumber = entry[kCGWindowLayer as String] as? NSNumber,
                  let pid = pid_t(exactly: pidNumber.intValue),
                  let id = UInt32(exactly: idNumber.uint64Value),
                  let layer = Int(exactly: layerNumber.int64Value),
                  layer == 0,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 80,
                  bounds.height >= 60 else { return nil }
            return Window(
                id: id,
                ownerPID: pid,
                title: entry[kCGWindowName as String] as? String,
                bounds: bounds)
        }
    }

    /// Edge, in pixels, of the square PNG tile published for every application in the browser.
    ///
    /// Every app list (Vamp Stream, Vamp Control, Vamp Assistant's own iOS app, the Mac client)
    /// draws the icon inside a fixed 42 pt row, so a 3x device samples it into 126 device pixels
    /// and 192 px keeps ~1.5x headroom over that. The previous 48 px tile was upscaled ~2.6x in
    /// the row, which is what read as low resolution. Kept identical to Vamp Sync's
    /// `HostApplicationRegistry.iconTilePixels` so both Stream providers look the same.
    private static let iconTilePixels = 192

    private func iconBase64(bundleIdentifier: String, icon: NSImage?) -> String? {
        if let cached = iconCache[bundleIdentifier] { return cached }
        guard let icon else { return nil }
        let side = Self.iconTilePixels
        let target = NSImage(size: NSSize(width: side, height: side))
        target.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        target.unlockFocus()
        guard let tiff = target.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let encoded = png.base64EncodedString()
        iconCache[bundleIdentifier] = encoded
        return encoded
    }

    nonisolated private static let applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    nonisolated private static func installedApplicationURLs() -> [URL] {
        let manager = FileManager.default
        var paths = Set<String>()
        var applications: [URL] = []
        for directory in applicationDirectories where manager.fileExists(atPath: directory.path) {
            guard let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                let path = url.standardizedFileURL.path
                if paths.insert(path).inserted { applications.append(url) }
            }
        }
        return applications
    }

    private static func isShareableWindow(_ windowID: CGWindowID) async -> Bool {
        guard ComputerPermission.screenRecordingGranted else { return false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true) else { return false }
        return content.windows.contains { $0.windowID == windowID && $0.isOnScreen }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
