import Foundation

enum BotComputerBackend: String, Codable, CaseIterable, Sendable {
    case isolatedWorkspace
    case appleContainer
    case macOSVirtualMachine

    var title: String {
        switch self {
        case .isolatedWorkspace: "Workspace"
        case .appleContainer: "Linux micro-VM"
        case .macOSVirtualMachine: "macOS VM"
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

    var errorDescription: String? {
        switch self {
        case .containersUnavailable:
            "Apple Container is not available on this Mac. Use an isolated workspace instead."
        case .commandFailed(let message): message
        case .recordMissing: "That bot computer no longer exists."
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
                    "--cpus", "2", "--memory", "2G",
                    "--volume", "\(record.workspacePath):/workspace",
                    "--workdir", "/workspace",
                    "--label", "com.beetcode.bot=\(record.profileID)",
                    "docker.io/library/alpine:latest", "sleep", "infinity",
                ],
                workingDirectory: root,
                timeout: 180,
                maxOutputBytes: 2 * 1024 * 1024)
        }
        guard !result.failed else {
            throw BotComputerError.commandFailed(Self.failureMessage(result.output))
        }
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
}
