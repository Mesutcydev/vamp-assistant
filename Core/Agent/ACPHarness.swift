import Foundation

/// An external agent harness (DeepSeek Harness, Claude Agent, Codex, Gemini
/// CLI, OpenCode, …) driven over the Agent Client Protocol: newline-delimited
/// JSON-RPC 2.0 on stdio (agentclientprotocol.com). One client covers every
/// harness in the ACP registry, so adding one is a row in `presets`.
struct ACPHarness: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
    /// Whitespace-split argv. ponytail: no shell quoting; a quoted argument
    /// needs a wrapper script until someone actually hits it.
    let command: String

    static let builtInID = "vamp"
    static let customID = "custom"

    /// Launch commands from the ACP registry (cdn.agentclientprotocol.com).
    static let presets: [ACPHarness] = [
        ACPHarness(id: "deepseek", name: "DeepSeek Harness", command: "dsh --profile acp"),
        ACPHarness(id: "claude", name: "Claude Agent", command: "npx -y @agentclientprotocol/claude-agent-acp"),
        ACPHarness(id: "codex", name: "Codex", command: "npx -y @agentclientprotocol/codex-acp"),
        ACPHarness(id: "gemini", name: "Gemini CLI", command: "gemini --acp"),
        ACPHarness(id: "opencode", name: "OpenCode", command: "opencode acp"),
        ACPHarness(id: "qwen", name: "Qwen Code", command: "npx -y @qwen-code/qwen-code --acp"),
        ACPHarness(id: "goose", name: "goose", command: "goose acp"),
        ACPHarness(id: "kimi", name: "Kimi CLI", command: "kimi acp"),
        ACPHarness(id: "cline", name: "Cline", command: "npx -y cline --acp")
    ]

    /// nil means Vamp's own AgentLoop.
    static func resolve(id: String, customCommand: String, registry: [ACPHarness] = []) -> ACPHarness? {
        if id == customID {
            let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : ACPHarness(id: customID, name: "Custom harness", command: command)
        }
        return (presets + registry).first { $0.id == id }
    }

    // MARK: ACP registry

    static let registryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    static func fetchRegistry() async throws -> [ACPHarness] {
        let (data, response) = try await URLSession.shared.data(from: registryURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ACPError("The ACP registry is unavailable right now.")
        }
        return parseRegistry(data)
    }

    /// Registry agents as launch commands. npx/uvx packages run as published
    /// (version-pinned); binary agents run by executable name, so they must be
    /// installed first. ponytail: no archive download; add it if users ask.
    static func parseRegistry(_ data: Data) -> [ACPHarness] {
        let platform = "darwin-aarch64" // Vamp ships for Apple Silicon only.
        let agents = (try? LFJSONValue.decode(data))?.objectValue?["agents"]?.arrayValue ?? []
        let presetNames = Set(presets.map { $0.name.lowercased() })
        return agents.compactMap { value -> ACPHarness? in
            guard let agent = value.objectValue,
                  let id = agent["id"]?.stringValue,
                  let name = agent["name"]?.stringValue,
                  !presetNames.contains(name.lowercased()),
                  let distribution = agent["distribution"]?.objectValue
            else { return nil }
            let launch: [String]
            let spec: [String: LFJSONValue]
            if let npx = distribution["npx"]?.objectValue, let package = npx["package"]?.stringValue {
                spec = npx
                launch = ["npx", "-y", package]
            } else if let uvx = distribution["uvx"]?.objectValue, let package = uvx["package"]?.stringValue {
                spec = uvx
                launch = ["uvx", package]
            } else if let binary = distribution["binary"]?.objectValue?[platform]?.objectValue,
                      let cmd = binary["cmd"]?.stringValue {
                spec = binary
                launch = [URL(fileURLWithPath: cmd).lastPathComponent]
            } else {
                return nil
            }
            // env(1) accepts NAME=value words before the command.
            let env = (spec["env"]?.objectValue ?? [:]).sorted { $0.key < $1.key }
                .compactMap { key, value in value.stringValue.map { "\(key)=\($0)" } }
            let args = spec["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return ACPHarness(id: "registry:" + id, name: name, command: (env + launch + args).joined(separator: " "))
        }
    }
}

/// A model a harness offers for a session.
struct ACPModel: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let name: String
}

/// A created harness session plus how to switch its model: `modelConfigID`
/// is the stable `session/set_config_option` id; nil falls back to the older
/// `session/set_model` call.
struct ACPSessionInfo: Sendable, Equatable {
    let id: String
    var models: [ACPModel]
    var currentModelID: String?
    var modelConfigID: String?
}

/// A notification (`id == nil`) or agent→client request from the harness.
struct ACPMessage: Sendable {
    let id: LFJSONValue?
    let method: String
    let params: [String: LFJSONValue]
}

struct ACPError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

actor ACPClient {
    let harness: ACPHarness

    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<LFJSONValue, Error>] = [:]
    private var subscriber: AsyncStream<ACPMessage>.Continuation?
    /// Harness stderr goes to a file, not a second pipe reader: two
    /// FileHandle.bytes readers starve each other. The tail explains failures
    /// such as "command not found" or a missing login.
    let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("vamp-acp-\(UUID().uuidString).log")

    init(harness: ACPHarness) {
        self.harness = harness
    }

    var isRunning: Bool { stdin != nil }
    /// From `initialize`: whether prompts may carry images and whether HTTP
    /// MCP servers can be handed over (stdio is always supported).
    private(set) var supportsImages = false
    private(set) var supportsHTTPMCP = false

    /// The user's login-shell PATH (nvm, fnm, volta, pyenv, …) ahead of the
    /// usual install dirs. GUI apps only inherit launchd's short PATH.
    static let searchPATH: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ([loginShellPATH()].compactMap { $0 } + [
            "\(home)/.local/bin", "\(home)/.opencode/bin", "\(home)/.bun/bin",
            "\(home)/.cargo/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
            ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]).joined(separator: ":")
    }()

    /// Runs the user's shell once, interactive + login so version managers
    /// initialise, and reads PATH between markers (rc files may print).
    private static func loginShellPATH() -> String? {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        shell.arguments = ["-ilc", "printf '__VAMP_PATH__%s__VAMP_END__' \"$PATH\""]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while shell.isRunning && Date() < deadline { usleep(20_000) }
        if shell.isRunning {
            kill(shell.processIdentifier, SIGKILL) // interactive shells ignore SIGTERM
            shell.waitUntilExit()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: "__VAMP_PATH__"),
              let end = text.range(of: "__VAMP_END__", range: start.upperBound..<text.endIndex)
        else { return nil }
        let path = String(text[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }

    /// Absolute path for a bare command, resolved against `searchPATH`.
    static func which(_ command: String) -> String {
        guard !command.contains("/") else { return command }
        for dir in searchPATH.split(separator: ":") {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return command
    }

    func start() async throws {
        let argv = harness.command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !argv.isEmpty else { throw ACPError("\(harness.name) has no launch command.") }

        let child = Process()
        // env resolves argv[0] (after any NAME=value words) against PATH.
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = argv
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPATH
        child.environment = environment

        let input = Pipe(), output = Pipe()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        child.standardInput = input
        child.standardOutput = output
        child.standardError = try FileHandle(forWritingTo: logURL)
        do {
            try child.run()
        } catch {
            throw ACPError("Could not start \(harness.name): \(error.localizedDescription)")
        }
        process = child
        stdin = input.fileHandleForWriting
        ChildProcessRegistry.register(child)

        Task { [weak self] in
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    await self?.dispatch(line)
                }
            } catch {}
            await self?.closed()
        }

        // First launch of an npx harness downloads the package: be patient.
        let result = try await request("initialize", params: [
            "protocolVersion": .number(1),
            "clientCapabilities": .object([
                "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]),
                "terminal": .bool(false)
            ]),
            "clientInfo": .object([
                "name": .string("vamp-assistant"),
                "title": .string("Vamp Assistant"),
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
            ])
        ], timeout: .seconds(300))
        let capabilities = result.objectValue?["agentCapabilities"]?.objectValue
        supportsImages = capabilities?["promptCapabilities"]?.objectValue?["image"]?.boolValue ?? false
        supportsHTTPMCP = capabilities?["mcpCapabilities"]?.objectValue?["http"]?.boolValue ?? false
    }

    func newSession(cwd: URL, mcpServers: [String: MCPServerConfig] = [:]) async throws -> ACPSessionInfo {
        let result = try await request("session/new", params: [
            "cwd": .string(cwd.path),
            "mcpServers": .array(Self.mcpServers(mcpServers, http: supportsHTTPMCP))
        ], timeout: .seconds(120))
        guard let object = result.objectValue, let id = object["sessionId"]?.stringValue else {
            throw ACPError("\(harness.name) did not return a session id.")
        }
        var session = ACPSessionInfo(id: id, models: [])
        Self.applyModels(from: object, to: &session)
        return session
    }

    func setModel(_ modelID: String, in session: ACPSessionInfo) async throws {
        if let configID = session.modelConfigID {
            _ = try await request("session/set_config_option", params: [
                "sessionId": .string(session.id), "configId": .string(configID), "value": .string(modelID)
            ], timeout: .seconds(30))
        } else {
            _ = try await request("session/set_model", params: [
                "sessionId": .string(session.id), "modelId": .string(modelID)
            ], timeout: .seconds(30))
        }
    }

    /// Runs one turn; returns the ACP stop reason (`end_turn`, `cancelled`, …).
    func prompt(sessionID: String, text: String, images: [ChatImage] = []) async throws -> String {
        let pictures: [LFJSONValue] = supportsImages ? images.map {
            .object(["type": .string("image"), "data": .string($0.data.base64EncodedString()),
                     "mimeType": .string($0.mimeType)])
        } : []
        let result = try await request("session/prompt", params: [
            "sessionId": .string(sessionID),
            "prompt": .array([.object(["type": .string("text"), "text": .string(text)])] + pictures)
        ], timeout: nil)
        return result.objectValue?["stopReason"]?.stringValue ?? "end_turn"
    }

    func cancel(sessionID: String) {
        try? write(["jsonrpc": .string("2.0"), "method": .string("session/cancel"),
                    "params": .object(["sessionId": .string(sessionID)])])
    }

    func respond(id: LFJSONValue, result: LFJSONValue) {
        try? write(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    /// One subscriber at a time: the controller's current run.
    func events() -> AsyncStream<ACPMessage> {
        subscriber?.finish()
        let (stream, continuation) = AsyncStream<ACPMessage>.makeStream()
        subscriber = continuation
        return stream
    }

    func stop() {
        // Closing stdin is ACP's graceful shutdown; terminate backs it up.
        try? stdin?.close()
        if let process, process.isRunning { process.terminate() }
        closed()
    }

    // MARK: Wire

    private func request(
        _ method: String,
        params: [String: LFJSONValue],
        timeout: Duration?
    ) async throws -> LFJSONValue {
        guard stdin != nil else { throw ACPError("\(harness.name) is not running.") }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(["jsonrpc": .string("2.0"), "id": .number(Double(id)),
                           "method": .string(method), "params": .object(params)])
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            if let timeout {
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.fail(id, ACPError("\(self?.harness.name ?? "Harness") timed out on \(method)."))
                }
            }
        }
    }

    private func write(_ message: [String: LFJSONValue]) throws {
        guard let stdin else { throw ACPError("\(harness.name) is not running.") }
        try stdin.write(contentsOf: Data((LFJSONValue.object(message).encoded() + "\n").utf8))
    }

    private func dispatch(_ line: String) {
        guard let object = (try? LFJSONValue.decode(line))?.objectValue else { return }
        if let method = object["method"]?.stringValue {
            let message = ACPMessage(id: object["id"], method: method, params: object["params"]?.objectValue ?? [:])
            // Only permission prompts are routed; we advertise no fs/terminal
            // capability, so any other agent→client request is refused.
            if let id = message.id, method != "session/request_permission" || subscriber == nil {
                try? write(["jsonrpc": .string("2.0"), "id": id, "error": .object([
                    "code": .number(-32601), "message": .string("Method not supported by Vamp Assistant")])])
                return
            }
            subscriber?.yield(message)
        } else if let id = object["id"]?.intValue, let continuation = pending.removeValue(forKey: id) {
            if let error = object["error"]?.objectValue {
                let message = error["message"]?.stringValue ?? "Unknown error"
                continuation.resume(throwing: ACPError("\(harness.name): \(message)"))
            } else {
                continuation.resume(returning: object["result"] ?? .null)
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func closed() {
        guard stdin != nil || process != nil else { return }
        stdin = nil
        if let process {
            ChildProcessRegistry.unregister(process)
            // Foundation aborts if a Process is released while still running.
            if process.isRunning { Task.detached { process.waitUntilExit() } }
        }
        process = nil
        let tail = (try? Data(contentsOf: logURL)).map { String(decoding: $0.suffix(800), as: UTF8.self) } ?? ""
        let detail = tail.isEmpty ? "" : "\n" + tail.trimmingCharacters(in: .whitespacesAndNewlines)
        for continuation in pending.values {
            continuation.resume(throwing: ACPError("\(harness.name) exited.\(detail)"))
        }
        pending.removeAll()
        subscriber?.finish()
        subscriber = nil
    }

    // MARK: Pure mapping helpers (unit-tested)

    /// Vamp's MCP config in ACP's shape. Stdio commands are made absolute
    /// (agents require it); HTTP servers only go to agents that accept them.
    static func mcpServers(_ servers: [String: MCPServerConfig], http: Bool) -> [LFJSONValue] {
        func pairs(_ values: [String: String]) -> LFJSONValue {
            .array(values.sorted { $0.key < $1.key }.map {
                .object(["name": .string($0.key), "value": .string($0.value)])
            })
        }
        return servers.sorted { $0.key < $1.key }.compactMap { name, config in
            if let command = config.command, !command.isEmpty {
                return .object(["name": .string(name), "command": .string(which(command)),
                                "args": .array(config.args.map(LFJSONValue.string)), "env": pairs(config.env)])
            }
            guard http, let url = config.url else { return nil }
            return .object(["type": .string("http"), "name": .string(name), "url": .string(url),
                            "headers": pairs(config.headers)])
        }
    }

    /// Reads the model list from a `session/new` result or a
    /// `config_option_update`: the stable select option in the "model"
    /// category first, then the older `models` state.
    static func applyModels(from object: [String: LFJSONValue], to session: inout ACPSessionInfo) {
        for option in object["configOptions"]?.arrayValue ?? [] {
            guard let select = option.objectValue, select["type"]?.stringValue == "select",
                  select["category"]?.stringValue == "model" || select["id"]?.stringValue == "model"
            else { continue }
            // Options are either flat or grouped ({group, name, options}).
            let flat = (select["options"]?.arrayValue ?? []).flatMap { $0.objectValue?["options"]?.arrayValue ?? [$0] }
            session.models = flat.compactMap { value in
                guard let item = value.objectValue, let id = item["value"]?.stringValue else { return nil }
                return ACPModel(id: id, name: item["name"]?.stringValue ?? id)
            }
            session.currentModelID = select["currentValue"]?.stringValue
            session.modelConfigID = select["id"]?.stringValue
            return
        }
        guard let state = object["models"]?.objectValue else { return }
        session.models = (state["availableModels"]?.arrayValue ?? []).compactMap { value in
            guard let item = value.objectValue, let id = item["modelId"]?.stringValue else { return nil }
            return ACPModel(id: id, name: item["name"]?.stringValue ?? id)
        }
        session.currentModelID = state["currentModelId"]?.stringValue
        session.modelConfigID = nil
    }

    /// Answers `session/request_permission` by picking the offered option
    /// whose kind matches the decision; no matching option means cancelled.
    static func permissionResult(options: [LFJSONValue], approved: Bool, always: Bool) -> LFJSONValue {
        let kinds = approved
            ? (always ? ["allow_always", "allow_once"] : ["allow_once", "allow_always"])
            : ["reject_once", "reject_always"]
        let optionID = kinds.lazy.compactMap { kind in
            options.first { $0.objectValue?["kind"]?.stringValue == kind }?
                .objectValue?["optionId"]?.stringValue
        }.first
        guard let optionID else { return cancelledPermission }
        return .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])])
    }

    static let cancelledPermission = LFJSONValue.object(["outcome": .object(["outcome": .string("cancelled")])])

    /// ACP tool kinds → Vamp tool names, so transcript icons/verbs match.
    static func toolName(kind: String?) -> String {
        switch kind ?? "" {
        case "read": "read_file"
        case "search": "search"
        case "edit", "delete": "apply_patch"
        case "move": "move_file"
        case "execute": "run_command"
        case "fetch": "web_fetch"
        default: kind ?? "tool"
        }
    }

    static func toolOutput(_ update: [String: LFJSONValue]) -> String {
        let parts = (update["content"]?.arrayValue ?? []).compactMap { item -> String? in
            guard let object = item.objectValue else { return nil }
            if let text = object["content"]?.objectValue?["text"]?.stringValue { return text }
            if object["type"]?.stringValue == "diff", let path = object["path"]?.stringValue {
                return "Edited \(path)"
            }
            return nil
        }
        if !parts.isEmpty { return parts.joined(separator: "\n") }
        guard let raw = update["rawOutput"] else { return "" }
        return raw.stringValue ?? raw.encoded()
    }
}
