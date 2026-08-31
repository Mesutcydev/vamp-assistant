import Foundation

enum BotComputerBackend: String, Codable, CaseIterable, Sendable {
    case isolatedWorkspace
    case appleContainer

    var title: String {
        switch self {
        case .isolatedWorkspace: "Workspace"
        case .appleContainer: "Linux micro-VM"
        }
    }
}

enum BotComputerState: String, Codable, Sendable {
    case prepared
    case running
    case stopped
    case unavailable
}

struct BotHostCapabilities: Codable, Equatable, Sendable {
    var architecture: String
    var macOSVersion: String
    var appleContainerExecutable: String?
    var appleContainerServiceRunning: Bool

    var supportsAppleContainers: Bool {
        architecture == "arm64" && appleContainerExecutable != nil
    }
}

/// One entry in a bot's workspace, as shown by the console file browser.
struct BotWorkspaceEntry: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    /// Path relative to the workspace root — never absolute, so a client can neither see the
    /// host layout nor round-trip a path that escapes the workspace.
    var path: String
    var name: String
    var isDirectory: Bool
    var byteSize: Int
    var modifiedAt: Date
}

struct BotComputerRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var profileID: String
    var name: String
    var backend: BotComputerBackend
    var state: BotComputerState
    var workspacePath: String
    var browserProfilePath: String
    var containerName: String?
    var createdAt: Date
    var updatedAt: Date
}

enum BotComputerError: Error, LocalizedError {
    case containersUnavailable
    case commandFailed(String)
    case recordMissing
    case unknownProfile
    case pathOutsideWorkspace
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .containersUnavailable:
            "Apple Container is not available on this Mac. Use an isolated workspace instead."
        case .commandFailed(let message): message
        case .recordMissing: "That bot computer no longer exists."
        case .unknownProfile: "Choose Builder, Reviewer, Navigator, or Researcher."
        case .pathOutsideWorkspace: "That path is outside the bot's workspace."
        case .notReadable(let name): "\(name) could not be read as text."
        }
    }
}

/// Persists bot computers and owns the Apple Container CLI boundary. A bot's
/// workspace and browser profile never overlap another bot's directories.
actor BotComputerService {
    private let root: URL
    private let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.root = root ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("BeetCode/BotComputers", isDirectory: true)
    }

    static let specialists: [(id: String, name: String)] = [
        ("builder", "Builder"),
        ("reviewer", "Reviewer"),
        ("navigator", "Navigator"),
        ("researcher", "Researcher"),
    ]

    func capabilities() -> BotHostCapabilities {
        let executable = Self.containerExecutable(fileManager: fileManager)
        let status = executable.flatMap { path in
            try? ShellRunner.runProcess(
                executable: path,
                arguments: ["system", "status"],
                workingDirectory: root.deletingLastPathComponent(),
                timeout: 5,
                maxOutputBytes: 64 * 1024)
        }
        return BotHostCapabilities(
            architecture: Self.machineArchitecture(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appleContainerExecutable: executable,
            appleContainerServiceRunning: status?.failed == false)
    }

    func load() throws -> [BotComputerRecord] {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return [] }
        return try JSONDecoder().decode(
            [BotComputerRecord].self,
            from: Data(contentsOf: catalogURL))
    }

    func prepare(
        profileID: String,
        name: String,
        backend: BotComputerBackend = .appleContainer
    ) throws -> BotComputerRecord {
        try ensureRoot()
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let browser = directory.appendingPathComponent("browser-profile", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: browser, withIntermediateDirectories: true)
        try Self.applyPrivatePermissions(to: directory)

        let now = Date()
        let slug = Self.slug(profileID.isEmpty ? name : profileID)
        let record = BotComputerRecord(
            id: id,
            profileID: profileID,
            name: name,
            backend: backend,
            state: .prepared,
            workspacePath: workspace.path,
            browserProfilePath: browser.path,
            containerName: backend == .appleContainer
                ? "beet-\(slug)-\(id.uuidString.lowercased().prefix(8))"
                : nil,
            createdAt: now,
            updatedAt: now)
        var records = try load()
        records.append(record)
        try save(records)
        return record
    }

    func prepareIfNeeded(
        profileID: String,
        name: String,
        backend: BotComputerBackend
    ) throws -> BotComputerRecord {
        if let existing = try load().first(where: { $0.profileID == profileID }) {
            return existing
        }
        return try prepare(profileID: profileID, name: name, backend: backend)
    }

    func prepareSpecialist(profileID: String) throws -> BotComputerRecord {
        guard let spec = Self.specialists.first(where: { $0.id == profileID }) else {
            throw BotComputerError.unknownProfile
        }
        return try prepareIfNeeded(
            profileID: spec.id,
            name: spec.name,
            backend: preferredBackend())
    }

    func prepareSpecialists() throws -> [BotComputerRecord] {
        let backend = preferredBackend()
        for spec in Self.specialists {
            _ = try prepareIfNeeded(profileID: spec.id, name: spec.name, backend: backend)
        }
        return try refresh()
    }

    func preferredBackend() -> BotComputerBackend {
        let caps = capabilities()
        return caps.supportsAppleContainers && caps.appleContainerServiceRunning
            ? .appleContainer : .isolatedWorkspace
    }

    func refresh() throws -> [BotComputerRecord] {
        var records = try load()
        guard let executable = Self.containerExecutable(fileManager: fileManager) else {
            return records.map { record in
                var copy = record
                if copy.backend == .appleContainer { copy.state = .unavailable }
                return copy
            }
        }
        let listed = try ShellRunner.runProcess(
            executable: executable,
            arguments: ["list", "--all", "--format", "json"],
            workingDirectory: root.deletingLastPathComponent(),
            timeout: 8,
            maxOutputBytes: 512 * 1024)
        if listed.failed { return records }
        let states = Self.containerStates(from: listed.output)
        for index in records.indices where records[index].backend == .appleContainer {
            guard let name = records[index].containerName else { continue }
            if let state = states[name] {
                records[index].state = state == "running" ? .running : .stopped
            } else if records[index].state != .prepared {
                records[index].state = .prepared
            }
        }
        try save(records)
        return records
    }

    func start(id: UUID) throws -> BotComputerRecord {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw BotComputerError.recordMissing
        }
        var record = records[index]
        if record.backend == .isolatedWorkspace {
            record.state = .running
            record.updatedAt = Date()
            records[index] = record
            try save(records)
            return record
        }
        guard record.backend == .appleContainer,
              let executable = Self.containerExecutable(fileManager: fileManager),
              let containerName = record.containerName
        else { throw BotComputerError.containersUnavailable }

        let existing = try ShellRunner.runProcess(
            executable: executable,
            arguments: ["list", "--all", "--format", "json"],
            workingDirectory: root,
            timeout: 8,
            maxOutputBytes: 512 * 1024)
        let resources = Self.containerResources()
        let result: CommandResult
        if existing.output.contains(containerName) {
            result = try ShellRunner.runProcess(
                executable: executable,
                arguments: ["start", containerName],
                workingDirectory: root,
                timeout: 30)
        } else {
            result = try ShellRunner.runProcess(
                executable: executable,
                arguments: [
                    "run", "--detach", "--name", containerName,
                    "--cpus", resources.cpus,
                    "--memory", resources.memory,
                    "--volume", "\(record.workspacePath):/workspace",
                    "--workdir", "/workspace",
                    "--label", "com.beetcode.bot=\(record.profileID)",
                    Self.guestImage, "sleep", "infinity",
                ],
                workingDirectory: root,
                timeout: 180,
                maxOutputBytes: 2 * 1024 * 1024)
        }
        guard !result.failed else {
            throw BotComputerError.commandFailed(Self.failureMessage(result.output))
        }
        Self.provisionGuestIfNeeded(
            executable: executable,
            containerName: containerName)
        record.state = .running
        record.updatedAt = Date()
        records[index] = record
        try save(records)
        return record
    }

    func stop(id: UUID) throws -> BotComputerRecord {
        var records = try load()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw BotComputerError.recordMissing
        }
        var record = records[index]
        if record.backend == .isolatedWorkspace {
            record.state = .stopped
            record.updatedAt = Date()
            records[index] = record
            try save(records)
            return record
        }
        guard let executable = Self.containerExecutable(fileManager: fileManager),
              let name = record.containerName
        else { throw BotComputerError.containersUnavailable }
        let result = try ShellRunner.runProcess(
            executable: executable,
            arguments: ["stop", name],
            workingDirectory: root,
            timeout: 30)
        guard !result.failed else {
            throw BotComputerError.commandFailed(Self.failureMessage(result.output))
        }
        record.state = .stopped
        record.updatedAt = Date()
        records[index] = record
        try save(records)
        return record
    }

    // MARK: - Console

    /// Run one command inside a bot's computer and return its combined output.
    ///
    /// This grants no capability the bot does not already have — `BotRunTools` executes in the
    /// same place — it only makes that surface visible and manual. Container-backed bots run
    /// through `container exec`; a workspace-backed bot runs on the host with its working
    /// directory pinned to the workspace, which is exactly how its own commands already run.
    func exec(id: UUID, command: String, timeout: TimeInterval = 30) throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let record = try load().first(where: { $0.id == id }) else {
            throw BotComputerError.recordMissing
        }
        let workspace = URL(fileURLWithPath: record.workspacePath, isDirectory: true)
        let result: CommandResult
        if record.backend == .appleContainer,
           let executable = Self.containerExecutable(fileManager: fileManager),
           let containerName = record.containerName {
            result = try ShellRunner.runProcess(
                executable: executable,
                arguments: Self.execArguments(
                    containerName: containerName,
                    command: Self.rewriteCommandForContainer(
                        trimmed, hostWorkspacePath: record.workspacePath)),
                workingDirectory: root,
                timeout: timeout,
                maxOutputBytes: 512 * 1024)
        } else {
            result = try ShellRunner.runProcess(
                executable: "/bin/sh",
                arguments: ["-lc", trimmed],
                workingDirectory: workspace,
                timeout: timeout,
                maxOutputBytes: 512 * 1024)
        }
        return result.output
    }

    /// List one directory of a bot's workspace.
    ///
    /// The workspace is a host directory bind-mounted at `/workspace`, so this reads it directly
    /// instead of paying for a container round-trip — and it keeps working for a workspace-backed
    /// bot, and for a container that is currently stopped.
    func listWorkspace(id: UUID, relativePath: String = "") throws -> [BotWorkspaceEntry] {
        let (root, directory) = try workspaceLocation(id: id, relativePath: relativePath)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants])
        return contents.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return BotWorkspaceEntry(
                path: Self.relativePath(of: url, under: root),
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                byteSize: values?.fileSize ?? 0,
                modifiedAt: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0))
        }
        .sorted {
            $0.isDirectory == $1.isDirectory
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.isDirectory
        }
    }

    /// Read one workspace file as text, capped so a stray binary or a multi-gigabyte log cannot
    /// be pulled into the app or across the wire.
    func readWorkspaceFile(
        id: UUID,
        relativePath: String,
        maxBytes: Int = 256 * 1024
    ) throws -> String {
        let (_, file) = try workspaceLocation(id: id, relativePath: relativePath)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw BotComputerError.notReadable(file.lastPathComponent)
        }
        return text
    }

    /// Resolve a client-supplied relative path against a bot's workspace, refusing anything that
    /// escapes it.
    ///
    /// This is the trust boundary for the console: `relativePath` arrives from the paired client.
    /// Both sides are symlink-resolved before comparison, so neither `../` nor a symlink planted
    /// inside the workspace can walk out of it.
    private func workspaceLocation(id: UUID, relativePath: String) throws -> (root: URL, target: URL) {
        guard let record = try load().first(where: { $0.id == id }) else {
            throw BotComputerError.recordMissing
        }
        let root = URL(fileURLWithPath: record.workspacePath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let cleaned = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !cleaned.isEmpty else { return (root, root) }
        let target = root.appendingPathComponent(cleaned)
            .resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw BotComputerError.pathOutsideWorkspace
        }
        return (root, target)
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let base = root.path
        guard resolved.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(resolved.dropFirst(base.count + 1))
    }

    static func containerCLI(fileManager: FileManager = .default) -> String? {
        containerExecutable(fileManager: fileManager)
    }

    static func execArguments(containerName: String, command: String) -> [String] {
        ["exec", "-w", "/workspace", containerName, "sh", "-lc", command]
    }

    /// Pinned base image.
    ///
    /// `alpine:latest` moves. A bot computer prepared today and started next month could come up
    /// on a different Alpine than the one `provisionGuestIfNeeded` was written against, and the
    /// failure would land as an `apk add` error inside a container nobody is watching. Existing
    /// containers are unaffected — they are restarted by name, never re-created.
    static let guestImage = "docker.io/library/alpine:3.21"

    /// Per-bot CPU and memory, sized against this Mac.
    ///
    /// This was a hardcoded 4 CPUs / 4 GB. With four specialists that is 16 GB and 16 cores
    /// requested regardless of what the machine has, so starting every specialist on a 16 GB Mac
    /// swapped the host. An eighth of RAM and a quarter of the cores per bot leaves room for
    /// macOS, the app, and the other three bots.
    static func containerResources(processInfo: ProcessInfo = .processInfo) -> (cpus: String, memory: String) {
        let cores = min(max(processInfo.activeProcessorCount / 4, 2), 8)
        let gigabytes = min(max(Int(processInfo.physicalMemory / 1_073_741_824) / 8, 2), 8)
        return (String(cores), "\(gigabytes)G")
    }

    static let guestPackages = [
        "bash", "git", "curl", "wget", "python3", "py3-pip", "nodejs", "npm",
        "make", "g++", "musl-dev", "linux-headers", "tar", "unzip", "zip",
        "jq", "openssh-client", "ca-certificates", "ripgrep", "patch",
        "diffutils", "findutils", "coreutils",
    ]

    static var provisionCommand: String {
        "apk add --no-cache " + guestPackages.joined(separator: " ")
    }

    static var guestReadyProbe: String {
        "command -v git >/dev/null && command -v python3 >/dev/null && command -v node >/dev/null && command -v bash >/dev/null && command -v curl >/dev/null"
    }

    static func rewriteCommandForContainer(_ command: String, hostWorkspacePath: String) -> String {
        guard !hostWorkspacePath.isEmpty else { return command }
        return command.replacingOccurrences(of: hostWorkspacePath, with: "/workspace")
    }

    private var catalogURL: URL { root.appendingPathComponent("computers.json") }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.applyPrivatePermissions(to: root)
    }

    private func save(_ records: [BotComputerRecord]) throws {
        try ensureRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: catalogURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogURL.path)
    }

    private static func containerExecutable(fileManager: FileManager) -> String? {
        ["/usr/local/bin/container", "/opt/homebrew/bin/container"].first {
            fileManager.isExecutableFile(atPath: $0)
        }
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func slug(_ value: String) -> String {
        let mapped = value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let compact = String(mapped).split(separator: "-").joined(separator: "-")
        return String((compact.isEmpty ? "bot" : compact).prefix(24))
    }

    private static func applyPrivatePermissions(to url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func failureMessage(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The bot computer command failed." : String(trimmed.prefix(500))
    }

    private struct ContainerListEntry: Decodable {
        struct Status: Decodable { var state: String }
        var id: String
        var status: Status
    }

    private static func containerStates(from output: String) -> [String: String] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONDecoder().decode([ContainerListEntry].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.status.state.lowercased()) })
    }

    /// Installs a capable guest toolchain the first time the VM is empty.
    /// Failure is non-fatal: the container still runs with busybox until a
    /// later start can reach Alpine's package index.
    static func provisionGuestIfNeeded(executable: String, containerName: String) {
        let probe = try? ShellRunner.runProcess(
            executable: executable,
            arguments: execArguments(containerName: containerName, command: guestReadyProbe),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: 8,
            maxOutputBytes: 16 * 1024)
        if probe?.failed == false { return }
        _ = try? ShellRunner.runProcess(
            executable: executable,
            arguments: execArguments(containerName: containerName, command: provisionCommand),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: 180,
            maxOutputBytes: 2 * 1024 * 1024)
    }
}
