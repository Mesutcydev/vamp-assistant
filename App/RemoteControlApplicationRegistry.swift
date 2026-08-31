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
        var applicationsByBundleID: [String: Application] = [:]

        for running in NSWorkspace.shared.runningApplications {
            guard running.activationPolicy == .regular,
                  let bundleIdentifier = running.bundleIdentifier,
                  bundleIdentifier != selfBundleID,
                  let name = running.localizedName else { continue }
            let window = bestWindow(in: windowsByPID[running.processIdentifier] ?? [])
            applicationsByBundleID[bundleIdentifier] = Application(
                bundleIdentifier: bundleIdentifier,
                name: name,
                isRunning: true,
                isActive: running.processIdentifier == frontmostPID,
                iconPNGBase64: includeIcons ? iconBase64(bundleIdentifier: bundleIdentifier, icon: running.icon) : nil,
                windowID: window?.id,
                windowTitle: window?.title,
                width: window.map { Double($0.bounds.width) } ?? 0,
                height: window.map { Double($0.bounds.height) } ?? 0)
        }

        for url in Self.installedApplicationURLs() {
                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier,
                      bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
                      bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true,
                      bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                      bundleIdentifier != selfBundleID,
                      applicationsByBundleID[bundleIdentifier] == nil else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                applicationsByBundleID[bundleIdentifier] = Application(
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
                    height: 0)
        }

        return applicationsByBundleID.values.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func launch(bundleIdentifier: String, clientViewportAspect: Double? = nil) async throws -> Application {
        if let clientViewportAspect {
            try Self.validate(aspect: clientViewportAspect)
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            running.activate(options: [.activateAllWindows])
        } else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                throw RegistryError.applicationUnavailable
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
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
            preferredBounds: window.bounds)
        try await Task.sleep(for: .milliseconds(350))
        // Same window in, same window out — resizing never changes a CGWindowID, and looking
        // it back up by bundle identifier would hand back the app's largest window instead.
        guard let application = self.application(forWindowID: windowID, includeIcons: true) else {
            throw RegistryError.windowUnavailable
        }
        return application
    }

    /// The Accessibility element for the window at `bounds`, falling back to the application's
    /// focused window when no frame matches (or when the caller named no window).
    ///
    /// AX exposes no public window-number attribute, so the on-screen frame is the join key
    /// back to the `CGWindowID` the client asked about. `kAXFocusedWindowAttribute` alone was
    /// not the same window: `resize(windowID:)` names one window, and an app with several
    /// windows can easily have focus on a different one — the fit then reshaped a window
    /// nobody was streaming. AXPosition and kCGWindowBounds are both global, points, top-left.
    nonisolated private static func axWindow(pid: pid_t, matching bounds: CGRect?) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        if let bounds {
            var windowsReference: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                application,
                kAXWindowsAttribute as CFString,
                &windowsReference
            ) == .success, let windows = windowsReference as? [AXUIElement] {
                for window in windows {
                    var positionReference: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(
                        window,
                        kAXPositionAttribute as CFString,
                        &positionReference
                    ) == .success,
                    let positionReference,
                    CFGetTypeID(positionReference) == AXValueGetTypeID() else { continue }
                    var position = CGPoint.zero
                    AXValueGetValue(positionReference as! AXValue, .cgPoint, &position)
                    if abs(position.x - bounds.origin.x) < 2, abs(position.y - bounds.origin.y) < 2 {
                        return window
                    }
                }
            }
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

    private func resizeFocusedWindow(
        pid: pid_t,
        toAspect aspect: Double,
        preferredBounds: CGRect?
    ) throws {
        guard AXIsProcessTrusted() else { throw RegistryError.accessibilityRequired }
        guard let window = Self.axWindow(pid: pid, matching: preferredBounds) else {
            throw RegistryError.windowUnavailable
        }
        var currentSize = CGSize(width: 1_280, height: 800)
        var sizeReference: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXSizeAttribute as CFString,
            &sizeReference
        ) == .success,
        let sizeReference,
        CFGetTypeID(sizeReference) == AXValueGetTypeID() {
            AXValueGetValue(sizeReference as! AXValue, .cgSize, &currentSize)
        }
        var currentPosition = preferredBounds?.origin ?? .zero
        var positionReference: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            window,
            kAXPositionAttribute as CFString,
            &positionReference
        ) == .success,
        let positionReference,
        CFGetTypeID(positionReference) == AXValueGetTypeID() {
            AXValueGetValue(positionReference as! AXValue, .cgPoint, &currentPosition)
        }

        let currentBounds = CGRect(origin: currentPosition, size: currentSize)
        let displayBounds = Self.displayBounds(containing: currentBounds)
        let targetFrame = Self.targetWindowFrame(
            current: currentBounds,
            display: displayBounds,
            aspect: CGFloat(aspect))
        var requestedSize = targetFrame.size
        guard let sizeValue = AXValueCreate(.cgSize, &requestedSize) else {
            throw RegistryError.windowUnavailable
        }
        // A fixed-size window, or one enforcing a minimum, returns a failure here. That is the
        // app declining a size, not a window that has gone away — and failing the whole request
        // on it made apps that stream perfectly well unstreamable. The snapshot below stays
        // authoritative for whatever geometry the window actually settled on.
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        // Keep the resized app entirely on the same display. AX may clamp the
        // requested size to an application's minimum; the subsequent registry
        // snapshot remains authoritative for the actual streamed geometry.
        var requestedPosition = targetFrame.origin
        if let positionValue = AXValueCreate(.cgPoint, &requestedPosition) {
            _ = AXUIElementSetAttributeValue(
                window,
                kAXPositionAttribute as CFString,
                positionValue)
        }
    }

    /// Produces the largest same-or-smaller window matching the phone viewport
    /// while keeping the complete frame visible on its Mac display. Preserving
    /// width for a portrait phone created windows thousands of points tall and
    /// made App Stream show only their middle; this instead preserves the
    /// constraining dimension and fits both axes.
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
        let currentSize = CGSize(
            width: min(max(current.width, 1), available.width),
            height: min(max(current.height, 1), available.height))
        let currentAspect = currentSize.width / currentSize.height
        var size: CGSize
        if aspect < currentAspect {
            size = CGSize(width: currentSize.height * aspect, height: currentSize.height)
        } else {
            size = CGSize(width: currentSize.width, height: currentSize.width / aspect)
        }
        let fitScale = min(1, min(available.width / size.width, available.height / size.height))
        size.width = max(1, floor(size.width * fitScale))
        size.height = max(1, floor(size.height * fitScale))
        // Never fit below what `onScreenWindows()` will still report as a window (80 x 60).
        // A portrait viewport sets width to height x ~0.46, so a window under ~173pt tall fitted
        // to under 80pt wide and vanished from discovery entirely — taking the stream target
        // with it, and turning a short wide window into one that could not be streamed at all.
        // Exact aspect is worth trading for a window that still exists.
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

    private func bestWindow(in windows: [Window]) -> Window? {
        windows.max { lhs, rhs in
            if lhs.area != rhs.area { return lhs.area < rhs.area }
            return lhs.id > rhs.id
        }
    }

    private func iconBase64(bundleIdentifier: String, icon: NSImage?) -> String? {
        if let cached = iconCache[bundleIdentifier] { return cached }
        guard let icon else { return nil }
        let side = 48
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
