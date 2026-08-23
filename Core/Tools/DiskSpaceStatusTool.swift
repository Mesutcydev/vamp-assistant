import Foundation

/// Read-only storage capacity check for the Mac's startup volume. Chat-only
/// models receive this narrow capability so a basic disk-space question never
/// falls back to System Settings, Computer Use, or a shell approval.
struct DiskSpaceStatusTool: AgentTool {
    let name = "disk_space_status"
    let summary = "Check total, used, and available disk space on this Mac. Use this before computer control for storage or free-space questions."
    let risk = ToolRisk.read
    let schemaText = #"{"type":"object","properties":{},"additionalProperties":false}"#

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: "/")
        guard let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
              total > 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let available = max(0, free)
        let used = max(0, total - available)
        let percent = Int((Double(used) / Double(total) * 100).rounded())
        return "Mac startup disk: \(Self.format(available)) available, "
            + "\(Self.format(used)) used of \(Self.format(total)) (\(percent)% used)."
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Read-only facts that ProcessInfo already exposes. This covers the other
/// common questions that should not open System Settings through Computer Use.
struct MacSystemStatusTool: AgentTool {
    let name = "mac_system_status"
    let summary = "Report macOS version, installed memory, processor count, uptime, and thermal state without opening System Settings."
    let risk = ToolRisk.read
    let schemaText = #"{"type":"object","properties":{},"additionalProperties":false}"#

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let process = ProcessInfo.processInfo
        let uptime = Duration.seconds(process.systemUptime)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
        let thermal: String = switch process.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return "Mac system: \(process.operatingSystemVersionString); "
            + "\(ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory)) installed memory; "
            + "\(process.activeProcessorCount) active processors; uptime \(uptime); thermal state \(thermal)."
    }
}
