import AppKit
import Carbon
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// A paced physical-key path for loginwindow. It is deliberately separate from
/// ordinary remote input because secure fields may ignore Unicode event payloads.
@MainActor
final class LoginWindowInputService {
    struct Key: Equatable {
        let code: CGKeyCode
        var modifiers: CGEventFlags
        var unicodeString: String?

        init(
            code: CGKeyCode,
            modifiers: CGEventFlags = [],
            unicodeString: String? = nil
        ) {
            self.code = code
            self.modifiers = modifiers
            self.unicodeString = unicodeString
        }
    }

    private let isLocked: () -> Bool
    private let hasAccessibility: () -> Bool
    private let resolveKeys: (String) throws -> [Key]
    private let postKey: (Key, Bool) throws -> Void
    private let sleep: (Duration) async throws -> Void
    private var isSubmitting = false

    convenience init() {
        let source = CGEventSource(stateID: .hidSystemState)
        self.init(
            isLocked: { ComputerPermission.sessionLocked },
            hasAccessibility: { ComputerPermission.accessibilityGranted },
            resolveKeys: Self.keysForCurrentLayout,
            postKey: { key, isDown in
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: key.code,
                    keyDown: isDown
                ) else {
                    throw RemoteMacControl.ParseError.message(
                        "Remote Unlock could not create a login key event.")
                }
                event.flags = key.modifiers
                if let unicodeString = key.unicodeString {
                    var units = Array(unicodeString.utf16)
                    event.keyboardSetUnicodeString(
                        stringLength: units.count,
                        unicodeString: &units)
                }
                event.post(tap: .cghidEventTap)
            },
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        isLocked: @escaping () -> Bool,
        hasAccessibility: @escaping () -> Bool,
        resolveKeys: @escaping (String) throws -> [Key],
        postKey: @escaping (Key, Bool) throws -> Void,
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.isLocked = isLocked
        self.hasAccessibility = hasAccessibility
        self.resolveKeys = resolveKeys
        self.postKey = postKey
        self.sleep = sleep
    }

    func submit(password: String) async throws {
        guard !isSubmitting else {
            throw RemoteMacControl.ParseError.message("An unlock attempt is already in progress.")
        }
        isSubmitting = true
        defer { isSubmitting = false }
        try checkCanType()
        guard !password.isEmpty, password.count <= 256,
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteMacControl.ParseError.message("Unsupported login password input.")
        }
        // Resolve everything before posting anything. A layout failure must not
        // type a partial password or expose the unsupported character in logs.
        let keys = try resolveKeys(password)
        guard var selectAll = try resolveKeys("a").first else {
            throw RemoteMacControl.ParseError.message("The Mac keyboard layout is unavailable.")
        }
        selectAll.modifiers.insert(.maskCommand)
        selectAll.unicodeString = nil

        // Wake/reveal the login form, then remove both the wake key and any
        // partial input left by an earlier failed attempt.
        try await stroke(Key(code: 49))
        try await sleep(.milliseconds(750))
        try await stroke(selectAll)
        try await stroke(Key(code: 51))
        try await sleep(.milliseconds(100))
        for key in keys {
            try await stroke(key)
            try await sleep(.milliseconds(25))
        }
        try await sleep(.milliseconds(100))
        try await stroke(Key(code: 36))
    }

    private func checkCanType() throws {
        try Task.checkCancellation()
        guard hasAccessibility() else { throw ComputerUseError.accessibilityNotGranted }
        guard isLocked() else {
            throw RemoteMacControl.ParseError.message(
                "The Mac is no longer locked; password entry stopped.")
        }
    }

    private func stroke(_ key: Key) async throws {
        try checkCanType()
        try postKey(key, true)
        do {
            try await sleep(.milliseconds(20))
        } catch {
            try? postKey(key, false)
            throw error
        }
        // Balance every down event even if a local unlock happened while the
        // key was held. The next suspension rechecks the lock state.
        try postKey(key, false)
    }

    static func keysForCurrentLayout(_ text: String) throws -> [Key] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            throw RemoteMacControl.ParseError.message("The Mac keyboard layout is unavailable.")
        }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        return try keys(text, layoutData: data)
    }

    static func keys(_ text: String, layoutData data: CFData) throws -> [Key] {
        guard let bytes = CFDataGetBytePtr(data) else {
            throw RemoteMacControl.ParseError.message("The Mac keyboard layout is unavailable.")
        }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let modifiers: [(UInt32, CGEventFlags)] = [
            (0, []), (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        var mapping: [String: Key] = [:]
        for (carbonFlags, flags) in modifiers {
            for code: CGKeyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var count = 0
                var units = [UniChar](repeating: 0, count: 8)
                let result = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), carbonFlags,
                    UInt32(LMGetKbdType()), 0, &deadKeyState,
                    units.count, &count, &units
                )
                guard result == noErr, deadKeyState == 0, count > 0 else { continue }
                let character = String(utf16CodeUnits: units, count: count)
                if mapping[character] == nil {
                    mapping[character] = Key(
                        code: code,
                        modifiers: flags,
                        unicodeString: character)
                }
            }
        }
        return try text.map { character in
            guard let key = mapping[String(character)] else {
                throw RemoteMacControl.ParseError.message(
                    "The password cannot be typed with the Mac's current keyboard layout.")
            }
            return key
        }
    }
}

/// Phone-driven Mac control over the existing Remote Sessions host.
/// Capture and input reuse the computer-use stack; pairing still gates every call.
enum RemoteMacControl {
    struct Frame: Equatable {
        enum Payload: Equatable {
            case h264(data: Data, keyframe: Bool, parameterSets: Data?)
            case jpeg(Data) // stills only
        }

        let payload: Payload
        let imageWidth: Int
        let imageHeight: Int
        let displayX: Double
        let displayY: Double
        let displayWidth: Double
        let displayHeight: Double

        var jpegData: Data? {
            if case .jpeg(let data) = payload { return data }
            return nil
        }
    }

    enum Command: Equatable {
        case click(x: Double?, y: Double?, button: String, count: Int)
        case move(x: Double, y: Double)
        case moveRelative(dx: Double, dy: Double)
        case down(String)
        case up(String)
        case scroll(x: Double?, y: Double?, dx: Double, dy: Double)
        case type(String)
        case key(String, modifiers: [String])
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self {
            case .message(let text): text
            }
        }
    }

    static func parse(_ object: [String: LFJSONValue]) -> Result<Command, ParseError> {
        parse(
            action: object["action"]?.stringValue ?? "",
            x: object["x"]?.numberValue,
            y: object["y"]?.numberValue,
            dx: object["dx"]?.numberValue,
            dy: object["dy"]?.numberValue,
            text: object["text"]?.stringValue,
            key: object["key"]?.stringValue,
            button: object["button"]?.stringValue,
            count: object["count"]?.intValue,
            modifiers: object["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    static func parse(
        action: String,
        x: Double? = nil,
        y: Double? = nil,
        dx: Double? = nil,
        dy: Double? = nil,
        text: String? = nil,
        key: String? = nil,
        button: String? = nil,
        count: Int? = nil,
        modifiers: [String] = []
    ) -> Result<Command, ParseError> {
        switch action.lowercased() {
        case "click":
            return .success(.click(
                x: x, y: y,
                button: normalizedButton(button),
                count: min(max(count ?? 1, 1), 3)))
        case "move":
            guard let x, let y else { return .failure(.message("Move needs x and y.")) }
            return .success(.move(x: x, y: y))
        case "rel":
            guard let x, let y else { return .failure(.message("Relative move needs dx and dy.")) }
            return .success(.moveRelative(dx: x, dy: y))
        case "down":
            return .success(.down(normalizedButton(button)))
        case "up":
            return .success(.up(normalizedButton(button)))
        case "scroll":
            return .success(.scroll(x: x, y: y, dx: dx ?? 0, dy: dy ?? 0))
        case "type":
            guard let text, !text.isEmpty else { return .failure(.message("Type needs text.")) }
            guard text.count <= ComputerTypeTool.maxCharacters else {
                return .failure(.message("Text is too long."))
            }
            return .success(.type(text))
        case "key":
            guard let key, !key.isEmpty else { return .failure(.message("Key needs a name.")) }
            if ComputerKey.isBlocked(key: key, modifiers: modifiers) {
                return .failure(.message("That shortcut is blocked."))
            }
            guard ComputerKey.keyCode(for: key) != nil else {
                return .failure(.message("Unknown key '\(key)'."))
            }
            return .success(.key(key, modifiers: modifiers))
        default:
            return .failure(.message("Unknown control action."))
        }
    }

    private static let inputExecutor = RemoteInputExecutor()

    static func perform(_ command: Command) async throws {
        try await inputExecutor.perform(command)
    }

    static func perform(_ commands: [Command]) async throws {
        try await inputExecutor.perform(commands)
    }

    static func releaseAll() async {
        await inputExecutor.releaseAll()
    }

    /// Mirrors Vamp Control's direct-distribution unlock path. The caller is
    /// responsible for authenticating and rate-limiting the request; this
    /// method only delivers the already-validated password to loginwindow.
    /// Nothing is persisted or logged.
    @MainActor private static let loginWindowInput = LoginWindowInputService()

    @MainActor static func unlockLoginWindow(password: String) async throws {
        try await loginWindowInput.submit(password: password)
    }

    private actor RemoteInputExecutor {
        private var heldButton: CGMouseButton?
        private var scrollRemainderX = 0.0
        private var scrollRemainderY = 0.0
        /// Authoritative last-posted cursor for relative moves (Vamp Control pattern).
        /// Re-reading the live cursor each event folds in external jitter.
        private var lastPostedPoint: CGPoint?
        private let eventSource = CGEventSource(stateID: .privateState)

        func perform(_ commands: [Command]) throws {
            for command in commands {
                try perform(command)
            }
        }

        func perform(_ command: Command) throws {
            guard ComputerPermission.accessibilityGranted else {
                throw ComputerUseError.accessibilityNotGranted
            }

            switch command {
            case .click(let x, let y, let button, let count):
                let point = resolvedPoint(x: x, y: y)
                lastPostedPoint = point
                postClick(at: point, button: mouseButton(button), clickCount: count)
            case .move(let x, let y):
                let point = ComputerEvents.clamped(x, y)
                lastPostedPoint = point
                postMove(to: point, dragging: heldButton)
            case .moveRelative(let dx, let dy):
                let anchor = lastPostedPoint ?? ComputerEvents.cursor()
                let point = ComputerEvents.clamped(anchor.x + dx, anchor.y + dy)
                lastPostedPoint = point
                postMove(to: point, dragging: heldButton)
            case .down(let button):
                let mouse = mouseButton(button)
                heldButton = mouse
                let point = resolvedPoint(x: nil, y: nil)
                lastPostedPoint = point
                postButton(mouse, down: true, at: point)
            case .up(let button):
                let mouse = mouseButton(button)
                heldButton = nil
                let point = resolvedPoint(x: nil, y: nil)
                lastPostedPoint = point
                postButton(mouse, down: false, at: point)
            case .scroll(let x, let y, let dx, let dy):
                scrollRemainderX += dx
                scrollRemainderY += dy
                let wholeX = scrollRemainderX.rounded(.towardZero)
                let wholeY = scrollRemainderY.rounded(.towardZero)
                scrollRemainderX -= wholeX
                scrollRemainderY -= wholeY
                guard wholeX != 0 || wholeY != 0 else { return }
                let point = resolvedPoint(x: x, y: y)
                lastPostedPoint = point
                postMove(to: point, dragging: nil)
                CGEvent(
                    scrollWheelEvent2Source: eventSource,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(wholeY),
                    wheel2: Int32(wholeX),
                    wheel3: 0
                )?.post(tap: .cghidEventTap)
            case .type(let text):
                ComputerEvents.postText(text)
            case .key(let name, let modifiers):
                guard let code = ComputerKey.keyCode(for: name) else {
                    throw ComputerUseError.unknownKey(name)
                }
                ComputerEvents.postKey(code, modifiers: ComputerKey.modifiers(for: modifiers))
            }
        }

        func releaseAll() {
            guard let heldButton else { return }
            self.heldButton = nil
            let point = lastPostedPoint ?? ComputerEvents.cursor()
            postButton(heldButton, down: false, at: point)
        }

        private func mouseButton(_ button: String) -> CGMouseButton {
            switch button {
            case "right": .right
            case "middle": .center
            default: .left
            }
        }

        private func resolvedPoint(x: Double?, y: Double?) -> CGPoint {
            if let x, let y {
                let point = ComputerEvents.clamped(x, y)
                lastPostedPoint = point
                return point
            }
            if let lastPostedPoint { return ComputerEvents.clamped(lastPostedPoint.x, lastPostedPoint.y) }
            let cursor = ComputerEvents.cursor()
            return ComputerEvents.clamped(cursor.x, cursor.y)
        }

        private func postMove(to point: CGPoint, dragging button: CGMouseButton?) {
            if let button {
                let types = ComputerEvents.mouseTypes(button)
                CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: types.dragged,
                    mouseCursorPosition: point,
                    mouseButton: button
                )?.post(tap: .cghidEventTap)
            } else {
                CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)
            }
        }

        private func postButton(_ button: CGMouseButton, down: Bool, at point: CGPoint) {
            let types = ComputerEvents.mouseTypes(button)
            CGEvent(
                mouseEventSource: eventSource,
                mouseType: down ? types.down : types.up,
                mouseCursorPosition: point,
                mouseButton: button
            )?.post(tap: .cghidEventTap)
        }

        private func postClick(at point: CGPoint, button: CGMouseButton, clickCount: Int) {
            let types = ComputerEvents.mouseTypes(button)
            let count = max(1, clickCount)
            let base = mach_absolute_time()
            let step: UInt64 = 1_000_000
            for state in 1...count {
                guard let down = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: types.down,
                    mouseCursorPosition: point,
                    mouseButton: button
                ), let up = CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: types.up,
                    mouseCursorPosition: point,
                    mouseButton: button
                ) else { continue }
                down.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                // Mach timestamps (not usleep) keep multi-clicks inside the system window.
                let offset = UInt64(state - 1) * step * 2
                down.timestamp = base &+ offset
                up.timestamp = base &+ offset &+ step
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    @MainActor
    static func attachedDisplays() -> [(id: UInt32, name: String, x: Double, y: Double, width: Double, height: Double)] {
        var result: [(id: UInt32, name: String, x: Double, y: Double, width: Double, height: Double)] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(number.uint32Value)
            let bounds = CGDisplayBounds(id)
            result.append((id, screen.localizedName, bounds.minX, bounds.minY, bounds.width, bounds.height))
        }
        return result
    }

    /// One-shot still JPEG for `/api/control/screen` — not used by the live H.264 stream.
    @MainActor
    static func captureDisplayJPEG(
        displayID: CGDirectDisplayID? = nil,
        maxWidth: Int? = RemoteStreamResolution.high.maxWidth,
        quality: Double = 0.88
    ) async throws -> Frame {
        guard ComputerPermission.screenRecordingGranted else {
            throw ComputerUseError.screenRecordingNotGranted
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display: SCDisplay
        if let displayID, let match = content.displays.first(where: { $0.displayID == displayID }) {
            display = match
        } else if let first = content.displays.first {
            display = first
        } else {
            throw ComputerUseError.noFocusedApp
        }
        let quartz = CGDisplayBounds(display.displayID)
        let pixelWidth = max(display.width, 1)
        let pixelHeight = max(display.height, 1)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = true
        let scale = maxWidth.map { min(1, Double($0) / Double(pixelWidth)) } ?? 1
        let width = max(2, Int((Double(pixelWidth) * scale).rounded(.down) / 2) * 2)
        let height = max(2, Int((Double(pixelHeight) * scale).rounded(.down) / 2) * 2)
        config.width = width
        config.height = height
        config.scalesToFit = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = RemoteMacScreenCapture.jpegData(from: image, quality: quality) else {
            throw ToolError.commandFailed(exitCode: 1)
        }
        return Frame(
            payload: .jpeg(jpeg),
            imageWidth: image.width,
            imageHeight: image.height,
            displayX: quartz.origin.x,
            displayY: quartz.origin.y,
            displayWidth: quartz.width,
            displayHeight: quartz.height)
    }

    /// One-shot still JPEG for a selected application window. The returned
    /// coordinate space remains the Mac's global Quartz space so input events
    /// map to the same pixels as the live window stream.
    @MainActor
    static func captureWindowJPEG(
        windowID: CGWindowID,
        maxWidth: Int? = RemoteStreamResolution.high.maxWidth,
        quality: Double = 0.88
    ) async throws -> Frame {
        guard ComputerPermission.screenRecordingGranted else {
            throw ComputerUseError.screenRecordingNotGranted
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID && $0.isOnScreen }) else {
            throw ComputerUseError.noFocusedApp
        }
        let bounds = window.frame
        let display = content.displays.max {
            CGDisplayBounds($0.displayID).intersection(bounds).area
                < CGDisplayBounds($1.displayID).intersection(bounds).area
        }
        let displayBounds = display.map { CGDisplayBounds($0.displayID) } ?? bounds
        let backingScale = display.map {
            max(Double($0.width) / max(displayBounds.width, 1), 1)
        } ?? 1
        let pixelWidth = max(Int((bounds.width * backingScale).rounded()), 1)
        let pixelHeight = max(Int((bounds.height * backingScale).rounded()), 1)
        let scale = maxWidth.map { min(1, Double($0) / Double(pixelWidth)) } ?? 1
        let config = SCStreamConfiguration()
        config.showsCursor = true
        config.width = max(2, Int((Double(pixelWidth) * scale).rounded(.down) / 2) * 2)
        config.height = max(2, Int((Double(pixelHeight) * scale).rounded(.down) / 2) * 2)
        config.scalesToFit = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = RemoteMacScreenCapture.jpegData(from: image, quality: quality) else {
            throw ToolError.commandFailed(exitCode: 1)
        }
        return Frame(
            payload: .jpeg(jpeg),
            imageWidth: image.width,
            imageHeight: image.height,
            displayX: bounds.origin.x,
            displayY: bounds.origin.y,
            displayWidth: bounds.width,
            displayHeight: bounds.height)
    }

    private static func normalizedButton(_ button: String?) -> String {
        switch button?.lowercased() {
        case "right": "right"
        case "middle", "center": "middle"
        default: "left"
        }
    }

}

private extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
