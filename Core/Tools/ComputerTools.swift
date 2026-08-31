import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Computer use: lets the agent observe and drive ANY macOS app, Claude-style.
///
/// Observation is dual-path by design:
/// - `computer_ui_tree` reads the Accessibility tree as TEXT — the reliable
///   path for local text-only models (Hermes, Qwythos): they get exact
///   element names and screen coordinates instead of guessing from pixels.
/// - `computer_screenshot` + `describe_image` is the pixel path for
///   vision-capable providers (BYOK GPT-4o/Claude, local SmolVLM2).
///
/// macOS gates this behind two TCC permissions, checked per call with a
/// clear error instead of a silent no-op:
/// - Accessibility (AX tree + posting CGEvents)
/// - Screen Recording (ScreenCaptureKit screenshots)
///
/// Observation tools are `.read` (auto-approved); every action that moves
/// the mouse, types, or scrolls is `.execute` and passes through the same
/// approval card as shell commands.

// MARK: - Permission preflight

enum ComputerPermission {
    /// Accessibility: required for the AX tree AND for posting input events.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Screen Recording: required for ScreenCaptureKit captures.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// The secure login window cannot be captured or driven by third-party
    /// processes. Report that state explicitly instead of letting remote
    /// control hang on a stream that macOS has suspended.
    static var sessionLocked: Bool {
        sessionIsLocked(CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    static func sessionIsLocked(_ session: [String: Any]?) -> Bool {
        session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Triggers the system prompt for Accessibility (shows the Settings pane).
    static func requestAccessibility() {
        // NOTE: the SDK declares kAXTrustedCheckOptionPrompt as a mutable
        // `var`, so referencing it is a concurrency error under approachable
        // concurrency. The key's value is the stable, documented literal
        // below — using it directly sidesteps the shared-mutable-state
        // diagnostic without `nonisolated(unsafe)` hacks.
        let options = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Triggers the system prompt for Screen Recording.
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}

enum ComputerUseError: Error, LocalizedError {
    case accessibilityNotGranted
    case screenRecordingNotGranted
    case noFocusedApp
    case unknownKey(String)
    case blockedShortcut(String)
    case textTooLong(Int)
    case staleReference(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission is not granted — ask for computer access or enable Vamp Assistant in System Settings → Privacy & Security → Accessibility, then retry."
        case .screenRecordingNotGranted:
            return "Screen Recording permission is not granted — ask for computer access or enable Vamp Assistant in System Settings → Privacy & Security → Screen Recording, then retry."
        case .noFocusedApp:
            return "No focused application to inspect."
        case .unknownKey(let name):
            return "Unknown key '\(name)'. Named keys: return, tab, escape, space, delete, forward_delete, left, right, up, down, home, end, page_up, page_down, f1…f12."
        case .blockedShortcut(let name):
            return "Refused to press '\(name)' — logout, lock screen, force-quit, and quit (cmd+q) are blocked."
        case .textTooLong(let count):
            return "computer_type is limited to \(ComputerTypeTool.maxCharacters) characters (got \(count)). Split the text."
        case .staleReference(let ref):
            return "Computer element reference '\(ref)' is stale. Call computer_ui_tree and retry with a fresh ref."
        }
    }
}

// MARK: - Keyboard mapping (pure, unit-tested)

enum ComputerKey {
    /// Named key → virtual keycode. Also accepts single characters.
    static func keyCode(for name: String) -> CGKeyCode? {
        let table: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
            "backspace": 51, "escape": 53, "esc": 53,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "page_up": 116, "page_down": 121,
            "forward_delete": 117, "help": 114,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        ]
        if let code = table[name.lowercased()] { return code }
        // Single printable characters: map the common US-layout ones.
        guard name.count == 1, let char = name.lowercased().first else { return nil }
        let chars: [Character: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "9": 27, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return chars[char]
    }

    /// Combinations that log the user out, lock the screen, force-quit the
    /// session, or quit the frontmost app (including Beet Code itself).
    /// Approval cards are not enough — a single mis-tap is irreversible.
    static func isBlocked(key: String, modifiers: [String]) -> Bool {
        let key = key.lowercased()
        var mods = Set(modifiers.map { $0.lowercased() })
        if mods.contains("command") { mods.insert("cmd") }
        if mods.contains("option") || mods.contains("opt") { mods.insert("alt") }
        if mods.contains("control") { mods.insert("ctrl") }

        let cmd = mods.contains("cmd")
        let alt = mods.contains("alt")
        // cmd+q quit · cmd+shift+q logout · ctrl+cmd+q lock · cmd+alt+shift+q force logout
        if cmd && key == "q" { return true }
        // cmd+opt+esc force-quit panel
        if cmd && alt && (key == "escape" || key == "esc") { return true }
        return false
    }

    /// Modifier names → CGEventFlags.
    static func modifiers(for names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }
}

// MARK: - Event posting

enum ComputerEvents {
    struct PhysicalKey: Equatable {
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags
    }

    /// Standard ANSI key positions used by macOS's secure login field. A
    /// Unicode payload alone is sufficient inside an ordinary app, but
    /// loginwindow also requires the corresponding physical key position.
    private static let ansiUnshiftedKeyCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
        "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49,
        "`": 50,
    ]

    private static let ansiShiftedKeyCodes: [Character: CGKeyCode] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5,
        "Z": 6, "X": 7, "C": 8, "V": 9, "B": 11,
        "Q": 12, "W": 13, "E": 14, "R": 15, "Y": 16, "T": 17,
        "!": 18, "@": 19, "#": 20, "$": 21, "^": 22, "%": 23,
        "+": 24, "(": 25, "&": 26, "_": 27, "*": 28, ")": 29,
        "}": 30, "O": 31, "U": 32, "{": 33, "I": 34, "P": 35,
        "L": 37, "J": 38, "\"": 39, "K": 40, ":": 41, "|": 42,
        "<": 43, "?": 44, "N": 45, "M": 46, ">": 47, "~": 50,
    ]

    static func loginWindowPhysicalKey(for character: Character) -> PhysicalKey? {
        if let keyCode = ansiUnshiftedKeyCodes[character] {
            return PhysicalKey(keyCode: keyCode, modifiers: [])
        }
        if let keyCode = ansiShiftedKeyCodes[character] {
            return PhysicalKey(keyCode: keyCode, modifiers: .maskShift)
        }
        return nil
    }

    /// Union of attached displays in Quartz space (top-left origin of the
    /// main display, y increasing downward). Matches AX frames and CGEvent.
    static func quartzDisplayUnion() -> CGRect {
        var bounds = CGRect.null
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            bounds = bounds.union(CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }
        return bounds
    }

    /// Clamps model-supplied coordinates to the union of all screens so a
    /// hallucinated point can never target outside the displays.
    ///
    /// Input is already Quartz / AX / CGEvent space (top-left origin of the
    /// main display). Do NOT flip Y — AX `kAXPosition` and `CGEvent`
    /// share that space. The previous Cocoa-frame flip landed every click
    /// mirrored about the primary display's horizontal midline.
    static func clamped(_ x: Double, _ y: Double, quartzBounds: CGRect) -> CGPoint {
        guard !quartzBounds.isNull, quartzBounds.width > 1, quartzBounds.height > 1 else {
            return CGPoint(x: x, y: y)
        }
        let clampedX = min(max(x, quartzBounds.minX), quartzBounds.maxX - 1)
        let clampedY = min(max(y, quartzBounds.minY), quartzBounds.maxY - 1)
        return CGPoint(x: clampedX, y: clampedY)
    }

    static func clamped(_ x: Double, _ y: Double) -> CGPoint {
        clamped(x, y, quartzBounds: quartzDisplayUnion())
    }

    static func cursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func mouseTypes(_ button: CGMouseButton) -> (down: CGEventType, up: CGEventType, dragged: CGEventType) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        default: (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }

    static func postMouseClick(at point: CGPoint, button: CGMouseButton, clickCount: Int) {
        let types = mouseTypes(button)
        let source = CGEventSource(stateID: .hidSystemState)
        for state in 1...max(1, clickCount) {
            if let down = CGEvent(mouseEventSource: source, mouseType: types.down, mouseCursorPosition: point, mouseButton: button),
               let up = CGEvent(mouseEventSource: source, mouseType: types.up, mouseCursorPosition: point, mouseButton: button) {
                down.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(state))
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
            if state < max(1, clickCount) {
                usleep(60_000)
            }
        }
    }

    static func postMouseButton(_ button: CGMouseButton, down: Bool, at point: CGPoint) {
        let types = mouseTypes(button)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: source,
            mouseType: down ? types.down : types.up,
            mouseCursorPosition: point,
            mouseButton: button
        )?.post(tap: .cghidEventTap)
    }

    static func postMouseMove(to point: CGPoint, dragging button: CGMouseButton? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let button {
            let types = mouseTypes(button)
            CGEvent(mouseEventSource: source, mouseType: types.dragged, mouseCursorPosition: point, mouseButton: button)?
                .post(tap: .cghidEventTap)
        } else {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
    }

    /// Types text as Unicode keystrokes — handles any layout/emoji, unlike
    /// per-character virtual keycodes.
    static func postText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            var units = Array(String(scalar).utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
    }

    static func postKey(_ code: CGKeyCode, modifiers: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func postScroll(at point: CGPoint, dx: Int, dy: Int) {
        postMouseMove(to: point)
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}

// MARK: - AX tree extraction

/// One flattened accessibility node. Value type so the walker (AppKit-free
/// except AX C APIs) stays testable: rendering is a pure function over these.
struct AXNodeInfo: Sendable, Equatable {
    var depth: Int
    var role: String
    var label: String
    var value: String
    var frame: CGRect
    var enabled: Bool
}

enum AXTreeWalker {
    static let maxDepth = 14
    static let maxNodes = 400

    /// Roles that carry no interaction or label value on their own.
    private static let noiseRoles: Set<String> = [
        "AXScrollArea", "AXGroup", "AXLayoutArea", "AXUnknown",
    ]

    /// Flattens the focused app's AX tree. Returns nil when nothing is focused.
    static func flattenFocusedApp() -> [AXNodeInfo]? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &focusedRef) == .success,
            let focusedRef
        else { return nil }
        // swiftlint:disable:next force_cast — AX contract guarantees AXUIElement.
        let app = focusedRef as! AXUIElement
        var nodes: [AXNodeInfo] = []
        walk(app, depth: 0, into: &nodes)
        return nodes
    }

    static func focusedApplicationPID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &focusedRef) == .success,
            let focusedRef else { return nil }
        var pid: pid_t = 0
        let app = focusedRef as! AXUIElement
        return AXUIElementGetPid(app, &pid) == .success ? pid : nil
    }

    private static func walk(_ element: AXUIElement, depth: Int, into nodes: inout [AXNodeInfo]) {
        guard depth <= maxDepth, nodes.count < maxNodes else { return }

        let role = stringAttribute(kAXRoleAttribute, of: element) ?? "AXUnknown"
        let label = stringAttribute(kAXTitleAttribute, of: element)
            ?? stringAttribute(kAXDescriptionAttribute, of: element)
            ?? ""
        var value = stringAttribute(kAXValueAttribute, of: element) ?? ""
        // Password fields must never enter the model context.
        if role == "AXSecureTextField", !value.isEmpty {
            value = "(redacted)"
        }
        let frame = frameAttribute(of: element)
        let enabled = boolAttribute(kAXEnabledAttribute, of: element) ?? true

        // Keep structural noise out of the model's context unless it carries
        // a label — unlabeled AXGroups are the bulk of any tree.
        if !noiseRoles.contains(role) || !label.isEmpty || !value.isEmpty {
            nodes.append(AXNodeInfo(
                depth: depth, role: role, label: label, value: value,
                frame: frame, enabled: enabled))
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
            let children = childrenRef as? [AXUIElement]
        else { return }
        for child in children {
            walk(child, depth: depth + 1, into: &nodes)
            if nodes.count >= maxNodes { return }
        }
    }

    /// One compact line per node: `button "Save" at (840,620) 64×28`.
    /// Coordinates are screen points in TOP-LEFT origin — the same space
    /// computer_click/computer_scroll take.
    static func render(_ nodes: [AXNodeInfo], references: [Int: String] = [:]) -> String {
        guard !nodes.isEmpty else { return "(no accessible elements found)" }
        var lines: [String] = []
        for (index, node) in nodes.enumerated() {
            let indent = String(repeating: "  ", count: min(node.depth, 10))
            var parts = [indent + node.role]
            if !node.label.isEmpty { parts.append("\"\(node.label)\"") }
            if !node.value.isEmpty, node.value != node.label {
                parts.append("value \"\(String(node.value.prefix(120)))\"")
            }
            if node.frame != .zero {
                parts.append("at (\(Int(node.frame.midX)),\(Int(node.frame.midY)))")
                parts.append("\(Int(node.frame.width))×\(Int(node.frame.height))")
            }
            if !node.enabled { parts.append("[disabled]") }
            if let ref = references[index] { parts.append("[ref=\(ref)]") }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Attribute helpers

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        if let string = ref as? String { return string }
        if let number = ref as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success,
              let number = ref as? NSNumber
        else { return nil }
        return number.boolValue
    }

    /// AX frames arrive in top-left origin screen points already.
    private static func frameAttribute(of element: AXUIElement) -> CGRect {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return .zero }
        var position = CGPoint.zero
        var size = CGSize.zero
        if let positionRef, CFGetTypeID(positionRef) == AXValueGetTypeID() {
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        }
        if let sizeRef, CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }
}

/// Keeps only the newest accessibility observation. Refs include a generation
/// so a second observation invalidates every prior coordinate instead of
/// letting the model unknowingly click a recycled index.
enum AXReferenceStore {
    struct Target {
        var point: CGPoint
        var pid: pid_t?
    }

    private struct State {
        var generation = 0
        var targets: [String: Target] = [:]
        var latestPID: pid_t?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func capture(_ nodes: [AXNodeInfo]) -> [Int: String] {
        let focusedPID = AXTreeWalker.focusedApplicationPID()
        return state.withLock { state in
            state.generation += 1
            state.targets.removeAll(keepingCapacity: true)
            state.latestPID = focusedPID
            let prefix = "c\(state.generation)"
            var references: [Int: String] = [:]
            for (index, node) in nodes.enumerated()
            where node.enabled && node.frame != .zero {
                let ref = "\(prefix):e\(index + 1)"
                references[index] = ref
                state.targets[ref] = Target(
                    point: CGPoint(x: node.frame.midX, y: node.frame.midY),
                    pid: focusedPID)
            }
            return references
        }
    }

    static func resolve(_ ref: String) -> Target? {
        state.withLock { $0.targets[ref] }
    }

    static var latestPID: pid_t? {
        state.withLock { $0.latestPID }
    }
}

enum ComputerTargetRestorer {
    @MainActor
    static func restore(_ pid: pid_t?) async {
        guard let pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
        try? await Task.sleep(for: .milliseconds(180))
    }
}

enum ComputerObservation {
    static func capture(limit: Int = 100) -> String {
        guard let nodes = AXTreeWalker.flattenFocusedApp() else {
            return "fresh observation:\n(no focused application)"
        }
        let bounded = Array(nodes.prefix(max(1, limit)))
        let references = AXReferenceStore.capture(bounded)
        return "fresh observation:\n" + AXTreeWalker.render(bounded, references: references)
    }
}

// MARK: - Tools

/// Contextual opt-in used only after the model identifies a concrete Mac UI
/// task. It is an execute-risk tool, so the existing approval card explains
/// the exact permission before any system prompt appears.
struct ComputerRequestAccessTool: AgentTool {
    let name = "computer_request_access"
    let summary = "Ask the user to enable the least Mac permission needed for a concrete computer-use task"
    let risk = ToolRisk.execute
    let schemaText = """
        {"type":"object","properties":{
          "capability":{"type":"string","enum":["accessibility","screenRecording"],"description":"Accessibility reads UI and posts input; Screen Recording captures pixels"},
          "reason":{"type":"string","description":"Short task-specific explanation shown in the approval card"}
        },"required":["capability","reason"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Enable \(call.string("capability") ?? "computer") access for \(call.string("reason") ?? "this task")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let capability = call.string("capability") else {
            throw ToolError.missingArgument("capability")
        }
        await MainActor.run {
            SettingsStore.shared.computerControlEnabled = true
            if capability == "screenRecording" {
                ComputerPermission.requestScreenRecording()
            } else {
                ComputerPermission.requestAccessibility()
            }
        }
        let granted = capability == "screenRecording"
            ? ComputerPermission.screenRecordingGranted
            : ComputerPermission.accessibilityGranted
        return granted
            ? "\(capability) access is enabled. Continue with the requested computer tool."
            : "Vamp Assistant opened the macOS privacy prompt for \(capability). Wait for the user to grant it, then call computer_status before continuing."
    }
}

struct ComputerStatusTool: AgentTool {
    let name = "computer_status"
    let summary = "Report computer-use permission status and the focused app"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{},"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let ax = ComputerPermission.accessibilityGranted
        let sr = ComputerPermission.screenRecordingGranted
        let frontmost = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.localizedName ?? "(none)"
        }
        return """
        focused app: \(frontmost)
        accessibility: \(ax ? "granted" : "NOT granted — computer_ui_tree/click/type/key/scroll will fail")
        screen recording: \(sr ? "granted" : "NOT granted — computer_screenshot will fail")
        """
    }
}

struct ComputerUITreeTool: AgentTool {
    let name = "computer_ui_tree"
    let summary = "Read the focused Mac app's accessibility tree with fresh click refs and coordinates"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{},"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let nodes = AXTreeWalker.flattenFocusedApp() else {
            throw ComputerUseError.noFocusedApp
        }
        let references = AXReferenceStore.capture(nodes)
        return AXTreeWalker.render(nodes, references: references)
    }
}

/// Testable window pick: prefer the frontmost app's largest on-screen
/// standard window. The previous implementation took `windows.first` that
/// wasn't Beet Code — ScreenCaptureKit order is not z-order.
struct CaptureCandidate: Equatable {
    var bundleID: String?
    var isOnScreen: Bool
    var layer: Int
    var area: CGFloat
}

enum CaptureWindowPicker {
    static func pickIndex(
        windows: [CaptureCandidate],
        frontmostBundleID: String?,
        selfBundleID: String?
    ) -> Int? {
        guard let frontmostBundleID, frontmostBundleID != selfBundleID else { return nil }
        let matching = windows.enumerated().filter {
            $0.element.isOnScreen && $0.element.bundleID == frontmostBundleID
        }
        let standard = matching.filter { $0.element.layer == 0 }
        let pool = standard.isEmpty ? matching : standard
        return pool.max(by: { $0.element.area < $1.element.area })?.offset
    }
}

struct ComputerScreenshotTool: AgentTool {
    let name = "computer_screenshot"
    let summary = "Capture the focused Mac app and inspect it with the installed local SmolVLM vision sidecar"
    let risk = ToolRisk.read

    let schemaText = """
        {"type":"object","properties":{
          "fullScreen":{"type":"boolean","description":"Capture the whole main display instead of the focused window"}
        },"required":[]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.screenRecordingGranted else {
            throw ComputerUseError.screenRecordingNotGranted
        }
        let fullScreen = call.bool("fullScreen") ?? false
        let image = try await Self.capture(fullScreen: fullScreen)
        let dir = context.workspace.root.appendingPathComponent(".beetcode/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ToolError.commandFailed(exitCode: 1)
        }
        try data.write(to: file)
        do {
            if let description = try await VisionProvider.describeLocallyIfAvailable(
                imageAt: file,
                prompt: "Describe the visible app UI accurately. Read important text, identify controls, layout problems, dialogs, loading or error states, and anything relevant to the user's task.")
            {
                return "screenshot saved to \(file.path)\nlocal SmolVLM inspection:\n\(description)"
            }
            return "screenshot saved to \(file.path) — no installed local vision sidecar was found; use describe_image if a vision API provider is configured."
        } catch {
            return "screenshot saved to \(file.path) — local SmolVLM inspection failed: \(error.localizedDescription)"
        }
    }

    /// SCScreenshotManager (macOS 14+): one call, no stream lifecycle.
    @MainActor
    private static func capture(fullScreen: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ComputerUseError.noFocusedApp
        }
        let filter: SCContentFilter
        if fullScreen {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else {
            let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let selfID = Bundle.main.bundleIdentifier
            let candidates = content.windows.map { window in
                CaptureCandidate(
                    bundleID: window.owningApplication?.bundleIdentifier,
                    isOnScreen: window.isOnScreen,
                    layer: window.windowLayer,
                    area: window.frame.width * window.frame.height)
            }
            if let index = CaptureWindowPicker.pickIndex(
                windows: candidates, frontmostBundleID: frontID, selfBundleID: selfID)
            {
                filter = SCContentFilter(desktopIndependentWindow: content.windows[index])
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
        }
        let config = SCStreamConfiguration()
        config.showsCursor = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

struct ComputerActivateAppTool: AgentTool {
    let name = "computer_activate_app"
    let summary = "Open or activate a Mac app directly; optionally open a trusted system-settings or web URL"
    let risk = ToolRisk.execute
    let schemaText = """
        {"type":"object","properties":{
          "appName":{"type":"string","description":"Installed app name, such as System Settings or Finder"},
          "bundleIdentifier":{"type":"string","description":"Optional exact bundle identifier"},
          "url":{"type":"string","description":"Optional https:// or x-apple.systempreferences: URL"},
          "capture_after":{"type":"boolean","default":true}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let target = call.string("url") ?? call.string("bundleIdentifier")
            ?? call.string("appName") ?? "application"
        return .command("Open or activate \(target)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let appName = call.string("appName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = call.string("bundleIdentifier")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedURL = call.string("url").flatMap(URL.init(string:))
        guard appName?.isEmpty == false || bundleID?.isEmpty == false || requestedURL != nil else {
            throw ToolError.missingArgument("appName, bundleIdentifier, or url")
        }
        if let requestedURL {
            let scheme = requestedURL.scheme?.lowercased()
            guard scheme == "https" || scheme == "x-apple.systempreferences" else {
                throw ToolError.commandFailed(exitCode: 1)
            }
            _ = await MainActor.run { NSWorkspace.shared.open(requestedURL) }
        } else {
            try await Self.activate(appName: appName, bundleID: bundleID)
        }
        try? await Task.sleep(for: .milliseconds(350))
        let target = requestedURL?.absoluteString ?? bundleID ?? appName ?? "application"
        var result = "opened or activated \(target)"
        if call.bool("capture_after") ?? true {
            result += "\n" + ComputerObservation.capture()
        }
        return result
    }

    @MainActor
    private static func activate(appName: String?, bundleID: String?) async throws {
        if let running = NSWorkspace.shared.runningApplications.first(where: { app in
            (bundleID != nil && app.bundleIdentifier == bundleID)
                || (appName != nil && app.localizedName?.localizedCaseInsensitiveCompare(appName!) == .orderedSame)
        }) {
            running.activate(options: [.activateAllWindows])
            return
        }
        let url: URL? = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? appName.flatMap { name in
                NSWorkspace.shared.fullPath(forApplication: name).map(URL.init(fileURLWithPath:))
            }
        guard let url else { throw ToolError.commandFailed(exitCode: 1) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

struct ComputerClickTool: AgentTool {
    let name = "computer_click"
    let summary = "Click a fresh computer_ui_tree ref or Mac screen coordinates"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "ref":{"type":"string","description":"Preferred: ref from the latest computer_ui_tree"},
          "x":{"type":"integer","description":"Screen X in points, top-left origin — use coordinates from computer_ui_tree"},
          "y":{"type":"integer","description":"Screen Y in points, top-left origin"},
          "button":{"type":"string","enum":["left","right"],"description":"Default left"},
          "clickCount":{"type":"integer","description":"2 for double-click. Default 1"},
          "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded UI tree after the action"}
        },"required":[]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        if let ref = call.string("ref") { return .command("computer_click [\(ref)]") }
        guard let x = call.number("x"), let y = call.number("y") else { return .none }
        return .command("computer_click at (\(Int(x)), \(Int(y)))")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        let requestedRef = call.string("ref")
        let rawPoint: CGPoint
        var targetPID: pid_t?
        if let requestedRef {
            guard let resolved = AXReferenceStore.resolve(requestedRef) else {
                throw ComputerUseError.staleReference(requestedRef)
            }
            rawPoint = resolved.point
            targetPID = resolved.pid
        } else if let x = call.number("x"), let y = call.number("y") {
            rawPoint = CGPoint(x: x, y: y)
        } else {
            throw ToolError.missingArgument("ref or x/y")
        }
        let button: CGMouseButton = (call.string("button") == "right") ? .right : .left
        let count = min(max(call.int("clickCount") ?? 1, 1), 3)
        await ComputerTargetRestorer.restore(targetPID)
        let point = await MainActor.run { ComputerEvents.clamped(rawPoint.x, rawPoint.y) }
        await Task.detached(priority: .userInitiated) {
            ComputerEvents.postMouseClick(at: point, button: button, clickCount: count)
        }.value
        var result = "clicked \(button == .left ? "left" : "right")×\(count) at (\(Int(point.x)), \(Int(point.y)))"
        if let requestedRef { result += " using [\(requestedRef)]" }
        if call.bool("capture_after") ?? true {
            try? await Task.sleep(for: .milliseconds(180))
            result += "\n" + ComputerObservation.capture()
        }
        return result
    }
}

struct ComputerTypeTool: AgentTool {
    let name = "computer_type"
    let summary = "Type text into a fresh UI ref or the currently focused Mac control"
    let risk = ToolRisk.execute

    static let maxCharacters = 4_000

    let schemaText = """
        {"type":"object","properties":{
          "ref":{"type":"string","description":"Preferred: editable ref from the latest computer_ui_tree; clicks it before typing"},
          "text":{"type":"string","description":"Text to type (any layout, Unicode-safe)"},
          "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded UI tree after the action"}
        },"required":["text"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let text = call.string("text") else { return .none }
        let target = call.string("ref").map { " into [\($0)]" } ?? ""
        return .command("computer_type\(target) \"\(String(text.prefix(80)))\"")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let text = call.string("text") else { throw ToolError.missingArgument("text") }
        guard text.count <= Self.maxCharacters else {
            throw ComputerUseError.textTooLong(text.count)
        }
        let requestedRef = call.string("ref")
        if let requestedRef {
            guard let target = AXReferenceStore.resolve(requestedRef) else {
                throw ComputerUseError.staleReference(requestedRef)
            }
            await ComputerTargetRestorer.restore(target.pid)
            let point = await MainActor.run {
                ComputerEvents.clamped(target.point.x, target.point.y)
            }
            await Task.detached(priority: .userInitiated) {
                ComputerEvents.postMouseClick(at: point, button: .left, clickCount: 1)
            }.value
            try? await Task.sleep(for: .milliseconds(80))
        }
        await Task.detached(priority: .userInitiated) {
            ComputerEvents.postText(text)
        }.value
        var result = "typed \(text.count) character(s)"
        if let requestedRef { result += " into [\(requestedRef)]" }
        if call.bool("capture_after") ?? true {
            try? await Task.sleep(for: .milliseconds(120))
            result += "\n" + ComputerObservation.capture()
        }
        return result
    }
}

struct ComputerKeyTool: AgentTool {
    let name = "computer_key"
    let summary = "Press a named key or shortcut (e.g. cmd+s, return, tab, arrows)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "key":{"type":"string","description":"return, tab, escape, space, delete, left/right/up/down, home, end, page_up, page_down, f1…f12, or a single character"},
          "modifiers":{"type":"array","items":{"type":"string","enum":["cmd","shift","alt","ctrl"]},"description":"Held while pressing, e.g. pass [cmd] for cmd+s"},
          "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded UI tree after the action"}
        },"required":["key"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let key = call.string("key") else { return .none }
        let mods = call.strings("modifiers").joined(separator: "+")
        if ComputerKey.isBlocked(key: key, modifiers: call.strings("modifiers")) {
            return .command("BLOCKED: \(mods.isEmpty ? key : mods + "+" + key)")
        }
        return .command("computer_key \(mods.isEmpty ? key : mods + "+" + key)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        guard let key = call.string("key") else { throw ToolError.missingArgument("key") }
        let modifierNames = call.strings("modifiers")
        if ComputerKey.isBlocked(key: key, modifiers: modifierNames) {
            throw ComputerUseError.blockedShortcut(
                modifierNames.isEmpty ? key : modifierNames.joined(separator: "+") + "+" + key)
        }
        guard let code = ComputerKey.keyCode(for: key) else {
            throw ComputerUseError.unknownKey(key)
        }
        let modifiers = ComputerKey.modifiers(for: modifierNames)
        await ComputerTargetRestorer.restore(AXReferenceStore.latestPID)
        await Task.detached(priority: .userInitiated) {
            ComputerEvents.postKey(code, modifiers: modifiers)
        }.value
        var result = "pressed \(key)"
        if call.bool("capture_after") ?? true {
            try? await Task.sleep(for: .milliseconds(120))
            result += "\n" + ComputerObservation.capture()
        }
        return result
    }
}

struct ComputerScrollTool: AgentTool {
    let name = "computer_scroll"
    let summary = "Scroll over a fresh UI ref or screen position (negative dy scrolls up)"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "ref":{"type":"string","description":"Preferred: ref from the latest computer_ui_tree"},
          "x":{"type":"integer"},"y":{"type":"integer"},
          "dx":{"type":"integer","description":"Horizontal scroll pixels. Default 0"},
          "dy":{"type":"integer","description":"Vertical scroll pixels; negative = up, positive = down"},
          "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded UI tree after the action"}
        },"required":["dy"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        let dy = call.int("dy") ?? 0
        let target = call.string("ref").map { " [\($0)]" } ?? ""
        return .command("computer_scroll\(target) dy=\(dy)")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard ComputerPermission.accessibilityGranted else {
            throw ComputerUseError.accessibilityNotGranted
        }
        let requestedRef = call.string("ref")
        let rawPoint: CGPoint
        var targetPID: pid_t?
        if let requestedRef {
            guard let resolved = AXReferenceStore.resolve(requestedRef) else {
                throw ComputerUseError.staleReference(requestedRef)
            }
            rawPoint = resolved.point
            targetPID = resolved.pid
        } else if let x = call.number("x"), let y = call.number("y") {
            rawPoint = CGPoint(x: x, y: y)
        } else {
            throw ToolError.missingArgument("ref or x/y")
        }
        let dx = call.int("dx") ?? 0
        guard let dy = call.int("dy") else { throw ToolError.missingArgument("dy") }
        await ComputerTargetRestorer.restore(targetPID)
        let point = await MainActor.run { ComputerEvents.clamped(rawPoint.x, rawPoint.y) }
        await Task.detached(priority: .userInitiated) {
            ComputerEvents.postScroll(at: point, dx: dx, dy: dy)
        }.value
        var result = "scrolled dx=\(dx) dy=\(dy) at (\(Int(point.x)), \(Int(point.y)))"
        if let requestedRef { result += " using [\(requestedRef)]" }
        if call.bool("capture_after") ?? true {
            try? await Task.sleep(for: .milliseconds(180))
            result += "\n" + ComputerObservation.capture()
        }
        return result
    }
}
