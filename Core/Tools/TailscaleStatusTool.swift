import Foundation

enum TailscaleStatusError: Error, LocalizedError {
    case commandMissing
    case invalidStatus

    var errorDescription: String? {
        switch self {
        case .commandMissing: "Tailscale command is not installed on this Mac."
        case .invalidStatus: "Tailscale is unavailable or did not return a valid status."
        }
    }
}

/// Read-only, one-shot Tailscale health check. Chat-only models need this
/// narrow tool because they intentionally do not receive a general shell.
/// It prevents simple status questions from turning into long computer-use
/// navigation sequences and never changes VPN/network state.
struct TailscaleStatusTool: AgentTool {
    let name = "tailscale_status"
    let summary = "Check whether Tailscale is running and this Mac is online. Use this before computer control for Tailscale status questions."
    let risk = ToolRisk.read
    let schemaText = #"{"type":"object","properties":{},"additionalProperties":false}"#

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw TailscaleStatusError.commandMissing
        }
        let result = try await Task.detached(priority: .userInitiated) {
            try ShellRunner.runProcess(
                executable: executable,
                arguments: ["status", "--json"],
                workingDirectory: context.workspace.root,
                timeout: 3,
                maxOutputBytes: 512 * 1_024)
        }.value
        guard !result.failed,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw TailscaleStatusError.invalidStatus
        }
        let state = object["BackendState"] as? String ?? "Unknown"
        let online = (object["Self"] as? [String: Any])?["Online"] as? Bool ?? false
        let ips = (object["TailscaleIPs"] as? [String]) ?? []
        let ipv4 = ips.first(where: { $0.contains(".") })
        let status = state == "Running" && online ? "running and online" : "not online"
        return "Tailscale is \(status). BackendState=\(state)"
            + (ipv4.map { ", private IPv4=\($0)" } ?? "")
    }
}
