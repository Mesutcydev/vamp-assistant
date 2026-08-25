import Foundation

enum RemoteInputCommand: Equatable, Sendable {
    case click(x: Double?, y: Double?, button: String, count: Int)
    case move(x: Double, y: Double)
    case relative(dx: Double, dy: Double)
    case down(button: String)
    case up(button: String)
    case scroll(x: Double?, y: Double?, dx: Double, dy: Double)
    case type(String)
    case key(String, modifiers: [String])

    var isMotion: Bool {
        switch self {
        case .move, .relative, .scroll: true
        default: false
        }
    }

    func wireBody() -> [String: Any] {
        switch self {
        case let .click(x, y, button, count):
            return Self.body(action: "click", x: x, y: y, button: button, count: count)
        case let .move(x, y):
            return Self.body(action: "move", x: x, y: y)
        case let .relative(dx, dy):
            return Self.body(action: "rel", x: dx, y: dy)
        case let .down(button):
            return Self.body(action: "down", button: button)
        case let .up(button):
            return Self.body(action: "up", button: button)
        case let .scroll(x, y, dx, dy):
            return Self.body(action: "scroll", x: x, y: y, dx: dx, dy: dy)
        case let .type(text):
            return Self.body(action: "type", text: text)
        case let .key(key, modifiers):
            return Self.body(action: "key", key: key, modifiers: modifiers)
        }
    }

    private static func body(
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
    ) -> [String: Any] {
        var body: [String: Any] = ["action": action]
        if let x { body["x"] = x }
        if let y { body["y"] = y }
        if let dx { body["dx"] = dx }
        if let dy { body["dy"] = dy }
        if let text { body["text"] = text }
        if let key { body["key"] = key }
        if let button { body["button"] = button }
        if let count { body["count"] = count }
        if !modifiers.isEmpty { body["modifiers"] = modifiers }
        return body
    }
}

struct RemoteInputCommandBuffer: Sendable {
    private var storage: [RemoteInputCommand] = []
    private var head = 0
    private(set) var coalescedCount: UInt64 = 0

    var commands: [RemoteInputCommand] {
        Array(storage.dropFirst(head))
    }

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var containsBarrier: Bool {
        storage.dropFirst(head).contains { !$0.isMotion }
    }

    @discardableResult
    mutating func append(_ command: RemoteInputCommand) -> Bool {
        compactIfNeeded()
        if isEmpty {
            storage.removeAll(keepingCapacity: true)
            head = 0
            storage.append(command)
            return false
        }
        let last = storage[storage.count - 1]
        switch (last, command) {
        case (.move, .move):
            storage[storage.count - 1] = command
        case let (.relative(previousDX, previousDY), .relative(dx, dy)):
            storage[storage.count - 1] = .relative(dx: previousDX + dx, dy: previousDY + dy)
        case let (.scroll(previousX, previousY, previousDX, previousDY), .scroll(x, y, dx, dy)):
            storage[storage.count - 1] = .scroll(
                x: x ?? previousX,
                y: y ?? previousY,
                dx: previousDX + dx,
                dy: previousDY + dy)
        default:
            storage.append(command)
            return false
        }
        coalescedCount &+= 1
        return true
    }

    mutating func removeFirst() -> RemoteInputCommand {
        precondition(!isEmpty)
        let command = storage[head]
        head += 1
        compactIfNeeded()
        return command
    }

    mutating func drain(maxCount: Int) -> [RemoteInputCommand] {
        guard maxCount > 0 else { return [] }
        var result: [RemoteInputCommand] = []
        result.reserveCapacity(min(maxCount, count))
        while !isEmpty && result.count < maxCount {
            result.append(removeFirst())
        }
        return result
    }

    mutating func trimMotion(keeping maximum: Int) {
        guard maximum >= 0 else { return }
        let live = Array(storage.dropFirst(head))
        let motionCount = live.reduce(into: 0) { count, command in
            if command.isMotion { count += 1 }
        }
        guard motionCount > maximum else { return }

        var toDrop = motionCount - maximum
        var kept: [RemoteInputCommand] = []
        kept.reserveCapacity(live.count - toDrop)
        for command in live {
            if command.isMotion, toDrop > 0 {
                toDrop -= 1
            } else {
                kept.append(command)
            }
        }
        storage = kept
        head = 0
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        coalescedCount = 0
    }

    private mutating func compactIfNeeded(force: Bool = false) {
        guard force || (head > 32 && head * 2 >= storage.count) else { return }
        storage.removeFirst(head)
        head = 0
    }
}
