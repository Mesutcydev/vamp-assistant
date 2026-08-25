import Foundation

enum BotRunCommand: Sendable {
    case list
    case start(profileID: String, modelID: String?, prompt: String)
    case orchestrate(modelID: String?, prompt: String)
    case steer(runID: UUID, message: String)
    case stop(runID: UUID)
    case respond(runID: UUID, action: String, value: String?)
}

struct OrchestrateBotsTool: AgentTool {
    let name = "orchestrate_bots"
    let summary = "Plan and run an adaptive, dependency-aware specialist workflow"
    let risk = ToolRisk.execute
    let schemaText = #"{"type":"object","properties":{"prompt":{"type":"string"},"modelID":{"type":"string","description":"Optional; defaults to the current Assistant model"}},"required":["prompt"]}"#

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Orchestrate specialist workflow: \(call.string("prompt") ?? "task")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let prompt = call.string("prompt") else { throw ToolError.missingArgument("prompt") }
        return await BotRunToolBridge.shared.perform(
            .orchestrate(modelID: call.string("modelID"), prompt: prompt))
    }
}

/// Keeps Core tools independent from the App-layer coordinator while still
/// routing dashboard, assistant, iOS, and web actions through one authority.
actor BotRunToolBridge {
    static let shared = BotRunToolBridge()
    typealias Handler = @Sendable (BotRunCommand) async -> String

    private var handler: Handler?

    func configure(_ handler: @escaping Handler) { self.handler = handler }

    func perform(_ command: BotRunCommand) async -> String {
        guard let handler else { return "Bot orchestration is not ready yet." }
        return await handler(command)
    }
}

struct BotRunsTool: AgentTool {
    let name = "bot_runs"
    let summary = "List Vamp specialist runs, readiness, queue state, and pending gates"
    let risk = ToolRisk.read
    let schemaText = #"{"type":"object","properties":{},"required":[]}"#

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        await BotRunToolBridge.shared.perform(.list)
    }
}

struct DelegateBotTool: AgentTool {
    let name = "delegate_bot"
    let summary = "Delegate a task to an isolated Vamp specialist computer"
    let risk = ToolRisk.execute
    let schemaText = """
        {"type":"object","properties":{
          "specialist":{"type":"string","enum":["builder","reviewer","navigator","researcher"]},
          "prompt":{"type":"string"},
          "modelID":{"type":"string","description":"Optional; defaults to the current Assistant model"}
        },"required":["specialist","prompt"]}
        """

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Delegate to \(call.string("specialist") ?? "specialist"): \(call.string("prompt") ?? "task")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let specialist = call.string("specialist") else { throw ToolError.missingArgument("specialist") }
        guard let prompt = call.string("prompt") else { throw ToolError.missingArgument("prompt") }
        return await BotRunToolBridge.shared.perform(
            .start(profileID: specialist, modelID: call.string("modelID"), prompt: prompt))
    }
}

struct BotSteerTool: AgentTool {
    let name = "bot_steer"
    let summary = "Send additional direction to an active specialist run"
    let risk = ToolRisk.execute
    let schemaText = #"{"type":"object","properties":{"runID":{"type":"string"},"message":{"type":"string"}},"required":["runID","message"]}"#

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Steer bot run \(call.string("runID") ?? "")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let rawID = call.string("runID"), let id = UUID(uuidString: rawID) else {
            throw ToolError.missingArgument("runID")
        }
        guard let message = call.string("message") else { throw ToolError.missingArgument("message") }
        return await BotRunToolBridge.shared.perform(.steer(runID: id, message: message))
    }
}

struct BotStopTool: AgentTool {
    let name = "bot_stop"
    let summary = "Stop an active or queued specialist run"
    let risk = ToolRisk.execute
    let schemaText = #"{"type":"object","properties":{"runID":{"type":"string"}},"required":["runID"]}"#

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Stop bot run \(call.string("runID") ?? "")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let rawID = call.string("runID"), let id = UUID(uuidString: rawID) else {
            throw ToolError.missingArgument("runID")
        }
        return await BotRunToolBridge.shared.perform(.stop(runID: id))
    }
}

struct BotRespondTool: AgentTool {
    let name = "bot_respond"
    let summary = "Approve, decline, answer, or resume a specialist run"
    let risk = ToolRisk.execute
    let schemaText = #"{"type":"object","properties":{"runID":{"type":"string"},"action":{"type":"string","enum":["approve","decline","answer","resume"]},"value":{"type":"string"}},"required":["runID","action"]}"#

    func preview(_ call: ParsedToolCall, in context: ToolContext) -> ApprovalPreview {
        .command("Respond to bot run \(call.string("runID") ?? "") with \(call.string("action") ?? "action")")
    }

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        guard let rawID = call.string("runID"), let id = UUID(uuidString: rawID) else {
            throw ToolError.missingArgument("runID")
        }
        guard let action = call.string("action") else { throw ToolError.missingArgument("action") }
        return await BotRunToolBridge.shared.perform(
            .respond(runID: id, action: action, value: call.string("value")))
    }
}
