import Foundation

/// Bridges BeetCode to the argent CLI (`argent run <tool> --args <json>`),
/// which exposes iOS-simulator (and Android/Chromium) device interaction:
/// boot, launch, tap, swipe, type, describe, screenshot. When argent is not
/// installed the tools fail with a clear message instead of crashing.
enum ArgentBridge {

    private static let candidates = [
        "/Users/\(NSUserName())/.local/bin/argent",
        "/opt/homebrew/bin/argent",
        "/usr/local/bin/argent",
        "/usr/bin/argent",
    ]

    static var executableURL: URL? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Last resort: resolve from PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "argent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    static var isAvailable: Bool { executableURL != nil }

    enum ArgentError: Error, LocalizedError {
        case unavailable
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "argent is not installed — install it (npm i -g @swmansion/argent) to let the agent drive the iOS simulator. The built-in panel still works for boot/install/launch/screenshots."
            case .failed(let output):
                return "argent failed: \(String(output.prefix(500)))"
            }
        }
    }

    /// Runs an argent tool with a JSON payload and returns its raw output.
    static func run(
        _ tool: String,
        args: [String: Any],
        outputPath: String? = nil,
        timeout: TimeInterval = 120
    ) throws -> String {
        guard let executable = executableURL else { throw ArgentError.unavailable }

        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: args)
        } catch {
            throw ArgentError.failed("cannot encode arguments: \(error)")
        }

        var arguments = ["run", tool, "--args", String(data: payload, encoding: .utf8) ?? "{}", "--json"]
        if let outputPath {
            arguments += ["--out", outputPath]
        }

        let result: CommandResult
        do {
            result = try ShellRunner.runProcess(
                executable: executable.path,
                arguments: arguments,
                workingDirectory: FileManager.default.temporaryDirectory,
                environment: ShellRunner.sanitizedEnvironment(),
                timeout: timeout)
        } catch {
            throw ArgentError.failed(error.localizedDescription)
        }

        guard !result.timedOut else {
            throw ArgentError.failed("argent \(tool) timed out after \(Int(timeout))s")
        }
        guard result.exitCode == 0 else {
            throw ArgentError.failed(result.output.isEmpty ? "exit \(result.exitCode)" : result.output)
        }
        return result.output
    }
}
