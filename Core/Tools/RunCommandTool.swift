import Foundation
import os

/// Marker for tools that can report a structured command outcome so
/// ToolExecutor marks failures from facts (exit code / timeout) instead of
/// string-sniffing rendered output.
protocol CommandExecuting {
    func executeCommand(_ call: ParsedToolCall, in context: ToolContext) async throws -> CommandResult
}

/// Runs a shell command in the workspace with a timeout, capturing combined
/// output. Every invocation requires permission-gate approval (or an
/// allowlisted exact form when the user enabled safe auto-approve).
/// Arbitrary `/bin/zsh -c` text remains available only behind an explicit
/// approval card — never auto-approved.
struct RunCommandTool: AgentTool, CommandExecuting {
    let name = "run_command"
    let summary = "Run a shell command in the workspace directory"
    let risk = ToolRisk.execute

    let schemaText = """
        {"type":"object","properties":{
          "command":{"type":"string","description":"Shell command line. Linux bot computers run POSIX sh inside the micro-VM; otherwise this is zsh on the Mac."},
          "timeout":{"type":"integer","description":"Seconds before the command is killed (default 120, max 600)"}
        },"required":["command"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        guard let command = call.string("command") else { return .none }
        return .command(command)
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let result = try await executeCommand(call, in: context)
        return Self.render(result)
    }

    func executeCommand(_ call: ParsedToolCall, in context: ToolContext) async throws -> CommandResult {
        guard let command = call.string("command"), !command.isEmpty else {
            throw ToolError.missingArgument("command")
        }
        let timeout = min(max(call.int("timeout") ?? 120, 1), 600)

        let workspace = context.workspace
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                if let linux = context.linuxContainer {
                    let rewritten = BotComputerService.rewriteCommandForContainer(
                        command,
                        hostWorkspacePath: linux.hostWorkspacePath)
                    return try ShellRunner.runProcess(
                        executable: linux.executable,
                        arguments: BotComputerService.execArguments(
                            containerName: linux.containerName,
                            command: rewritten),
                        workingDirectory: URL(fileURLWithPath: linux.hostWorkspacePath, isDirectory: true),
                        timeout: Double(timeout),
                        cancelCheck: {
                            cancelled.withLock { $0 } || context.isCancellationRequested
                        })
                }
                return try ShellRunner.run(
                    command: command,
                    workingDirectory: workspace.root,
                    timeout: Double(timeout),
                    cancelCheck: {
                        cancelled.withLock { $0 } || context.isCancellationRequested
                    })
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Renders a typed result the way the agent expects to see it.
    static func render(_ result: CommandResult) -> String {
        let body = truncate(result.output)
        if result.timedOut {
            return "error: command timed out\npartial output:\n\(body)"
        }
        if result.exitCode == 0 {
            return body.isEmpty ? "(no output, exit 0)" : body
        }
        return "exit status \(result.exitCode)\n\(body)"
    }

    static func truncate(_ output: String, limit: Int = 16_384) -> String {
        guard output.utf8.count > limit else { return output }
        let head = String(output.prefix(limit / 2))
        let tail = String(output.suffix(limit / 4))
        return head + "\n…[output truncated]…\n" + tail
    }
}