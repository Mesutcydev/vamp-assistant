import Darwin
import Foundation

/// Project/user hooks — ZCode-style subprocess JSON, not JS plugins.
///
/// Config (merged user-global then workspace-local):
/// ```json
/// { "hooks": {
///     "PreToolUse": [{ "command": "/usr/bin/python3", "args": ["hook.py"], "timeout": 5 }],
///     "PostToolUse": [],
///     "Stop": []
/// } }
/// ```
///
/// Each hook receives one JSON object on stdin and may reply with JSON on
/// stdout. PreToolUse can `allow`, `deny`, or `rewrite` arguments. A hook
/// crash or timeout never blocks the agent (fail-open) — only an explicit
/// `deny` (or non-zero exit with a reason) stops a tool.
struct HookConfig: Codable, Equatable, Sendable {
    var command: String
    var args: [String] = []
    var timeout: Double = 5
}

struct HookFile: Codable, Equatable, Sendable {
    var hooks: [String: [HookConfig]] = [:]
}

enum HookEvent: String, Sendable {
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case stop = "Stop"
}

enum HookDecision: Equatable, Sendable {
    case allow
    case deny(reason: String)
    case rewrite(arguments: LFJSONValue)
}

struct HookRunner: Sendable {
    var preToolUse: [HookConfig]
    var postToolUse: [HookConfig]
    var stop: [HookConfig]
    var workspaceRoot: URL

    static var userConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".beetcode/hooks.json")
    }

    static func workspaceConfigURL(root: URL) -> URL {
        root.appendingPathComponent(".beetcode/hooks.json")
    }

    static func load(workspaceRoot: URL, includeWorkspace: Bool = false) -> HookRunner {
        var pre: [HookConfig] = []
        var post: [HookConfig] = []
        var stop: [HookConfig] = []
        var urls = [userConfigURL]
        if includeWorkspace {
            urls.append(workspaceConfigURL(root: workspaceRoot))
        }
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(HookFile.self, from: data)
            else { continue }
            pre += file.hooks[HookEvent.preToolUse.rawValue] ?? []
            post += file.hooks[HookEvent.postToolUse.rawValue] ?? []
            stop += file.hooks[HookEvent.stop.rawValue] ?? []
        }
        return HookRunner(preToolUse: pre, postToolUse: post, stop: stop, workspaceRoot: workspaceRoot)
    }

    static func disabled(workspaceRoot: URL) -> HookRunner {
        HookRunner(preToolUse: [], postToolUse: [], stop: [], workspaceRoot: workspaceRoot)
    }

    func runPreToolUse(tool: String, arguments: LFJSONValue) -> HookDecision {
        var current = arguments
        for hook in preToolUse {
            let payload: LFJSONValue = .object([
                "event": .string(HookEvent.preToolUse.rawValue),
                "tool": .string(tool),
                "arguments": current,
            ])
            switch invoke(hook, payload: payload) {
            case .deny(let reason):
                return .deny(reason: reason)
            case .rewrite(let next):
                current = next
            case .allow:
                continue
            }
        }
        if current != arguments { return .rewrite(arguments: current) }
        return .allow
    }

    func runPostToolUse(tool: String, arguments: LFJSONValue, output: String, failed: Bool) {
        let payload: LFJSONValue = .object([
            "event": .string(HookEvent.postToolUse.rawValue),
            "tool": .string(tool),
            "arguments": arguments,
            "output": .string(String(output.prefix(8_000))),
            "failed": .bool(failed),
        ])
        for hook in postToolUse {
            _ = invoke(hook, payload: payload)
        }
    }

    func runStop(reason: String) {
        let payload: LFJSONValue = .object([
            "event": .string(HookEvent.stop.rawValue),
            "reason": .string(reason),
        ])
        for hook in stop {
            _ = invoke(hook, payload: payload)
        }
    }

    // MARK: Subprocess

    /// Ignore SIGPIPE once, process-wide: a hook that exits before its stdin
    /// is drained makes the write fail with EPIPE, which would otherwise
    /// terminate the app.
    private static let sigpipeIgnored: Void = {
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    /// Writes the hook payload without ever blocking the caller. The write
    /// runs on a background queue against a duplicate of the pipe's write fd,
    /// with a deadline and EPIPE/EAGAIN handling; the duplicate is closed
    /// afterwards, which gives the hook its EOF.
    private func writePayload(_ data: Data, to pipe: Pipe, timeout: TimeInterval) {
        _ = Self.sigpipeIgnored
        let fd = dup(pipe.fileHandleForWriting.fileDescriptor)
        guard fd >= 0 else { return }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            var offset = 0
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                while offset < data.count, Date() < deadline {
                    let written = Darwin.write(fd, base + offset, data.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno == EINTR {
                        continue
                    } else if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        usleep(5_000)
                    } else {
                        break  // EPIPE or a closed pipe: fail open.
                    }
                }
            }
            close(fd)
        }
    }

    private func invoke(_ hook: HookConfig, payload: LFJSONValue) -> HookDecision {
        guard !hook.command.isEmpty else { return .allow }
        let process = Process()
        process.currentDirectoryURL = workspaceRoot
        process.executableURL = URL(fileURLWithPath: hook.command)
        process.arguments = hook.args
        process.environment = ShellRunner.sanitizedEnvironment()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return .allow
        }
        let timeout = min(max(0.2, hook.timeout), 15)
        // Writing the whole payload before reading any output could block
        // forever on a hook that never drains stdin, and FileHandle.write
        // raises an uncatchable exception on EPIPE. Hand the bytes to a
        // non-blocking writer with its own deadline instead.
        writePayload(Data(payload.encoded().utf8), to: stdin, timeout: min(timeout, 2))
        try? stdin.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return .allow
        }
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let reason = text.isEmpty
                ? "hook exited \(process.terminationStatus)"
                : String(text.prefix(400))
            return .deny(reason: reason)
        }
        guard !text.isEmpty, let json = try? LFJSONValue.decode(text),
              let object = json.objectValue
        else { return .allow }

        let action = (object["action"]?.stringValue ?? "allow").lowercased()
        switch action {
        case "deny", "block":
            let reason = object["reason"]?.stringValue ?? "denied by hook"
            return .deny(reason: reason)
        case "rewrite":
            if let next = object["arguments"] {
                return .rewrite(arguments: next)
            }
            return .allow
        default:
            return .allow
        }
    }
}
