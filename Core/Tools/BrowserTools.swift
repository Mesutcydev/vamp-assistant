import Foundation

/// Agent-facing tools that drive the in-app browser (`BrowserController`).
///
/// Risk model: extraction is `.read` (auto-approved, no side effects on the
/// page); navigation, clicking, typing, and raw JS are `.execute` and go
/// through the normal approval card — the user sees exactly what the agent
/// wants to do on the live page.
///
/// Every controller access hops onto the MainActor via a @MainActor Task:
/// the controller is MainActor-isolated (it owns a WKWebView) while tool
/// execution is not.
enum BrowserTools {

    @MainActor
    private static func actionObservation(
        _ controller: BrowserController,
        elementLimit: Int = 30
    ) async throws -> String {
        let elements = try await controller.extractInteractiveElements(limit: elementLimit)
        return "fresh observation:\n" + controller.pageInfo() + "\n" +
            BrowserController.renderInteractiveElements(elements)
    }

    private static func captureAfter(_ call: ParsedToolCall) -> Bool {
        call.boolean("capture_after") ?? call.boolean("captureAfter") ?? true
    }

    // MARK: Read

    struct ReadTool: AgentTool {
        let name = "browser_read"
        let summary = "Read the open page: interactive element refs, visible text, links, and URL"
        let risk = ToolRisk.read
        let schemaText = """
            {"type":"object","properties":{
              "what":{"type":"string","enum":["elements","text","links","info"]},
              "limit":{"type":"integer"}
            },"required":["what"]}
            """

        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
            let what = call.string("what") ?? "text"
            let limit = call.integer("limit")
            return try await Task { @MainActor in
                let controller = BrowserController.shared
                guard controller.hasOpenPage else {
                    return "The browser has no page open. Use browser_navigate first."
                }
                switch what {
                case "elements":
                    let elements = try await controller.extractInteractiveElements(limit: limit ?? 80)
                    return controller.pageInfo() + "\n" +
                        BrowserController.renderInteractiveElements(elements)
                case "text":
                    return try await controller.extractText(limit: limit ?? 12_000)
                case "links":
                    let links = try await controller.extractLinks(limit: limit ?? 60)
                    if links.isEmpty { return "No links found on the page." }
                    return links.enumerated()
                        .map { index, link in "\(index + 1). \(link.text.isEmpty ? "(no text)" : link.text) → \(link.href)" }
                        .joined(separator: "\n")
                default:
                    return controller.pageInfo()
                }
            }.value
        }
    }

    struct ScreenshotTool: AgentTool {
        let name = "browser_screenshot"
        let summary = "Save a PNG snapshot of the open page into the workspace"
        let risk = ToolRisk.read
        let schemaText = """
            {"type":"object","properties":{},"required":[]}
            """

        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
            try await Task { @MainActor in
                let controller = BrowserController.shared
                guard controller.hasOpenPage else {
                    return "The browser has no page open. Use browser_navigate first."
                }
                let dir = context.workspace.root
                    .appendingPathComponent(".beetcode/screenshots", isDirectory: true)
                let path = dir.appendingPathComponent("browser-\(Int(Date().timeIntervalSince1970)).png")
                let saved = try await controller.snapshot(to: path)
                return "screenshot saved to \(saved.path)"
            }.value
        }
    }

    // MARK: Actions (approval-gated)

    struct NavigateTool: AgentTool {
        let name = "browser_navigate"
        let summary = "Open a URL in the in-app browser (http/https)"
        let risk = ToolRisk.execute
        let schemaText = """
            {"type":"object","properties":{
              "url":{"type":"string"},
              "wait":{"type":"boolean","default":true},
              "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded element observation after the action"}
            },"required":["url"]}
            """

        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
            guard let raw = call.string("url") else { throw ToolError.missingArgument("url") }
            let wait = call.boolean("wait") ?? true
            let captureAfter = BrowserTools.captureAfter(call)
            return try await Task { @MainActor in
                let controller = BrowserController.shared
                let url = try controller.open(raw, filePolicy: .confined(context.workspace))
                // Agent navigation may start before the docked panel exists.
                // Reveal it so the user can see and continue using the same
                // loaded page instead of believing the browser is broken.
                NotificationCenter.default.post(name: .openBrowserPanel, object: nil)
                if wait { await controller.waitForLoad() }
                let result = "opened \(url.absoluteString)"
                return captureAfter
                    ? result + "\n" + (try await BrowserTools.actionObservation(controller))
                    : result + "\n" + controller.pageInfo()
            }.value
        }
    }

    struct ClickTool: AgentTool {
        let name = "browser_click"
        let summary = "Click an element by document-scoped ref, CSS selector, or visible text"
        let risk = ToolRisk.execute
        let schemaText = """
            {"type":"object","properties":{
              "ref":{"type":"string","description":"Preferred: ref from browser_read what=elements"},
              "selector":{"type":"string"},
              "text":{"type":"string"},
              "wait":{"type":"boolean","default":true},
              "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded element observation after the action"}
            },"required":[]}
            """

        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
            let wait = call.boolean("wait") ?? true
            let captureAfter = BrowserTools.captureAfter(call)
            return try await Task { @MainActor in
                let controller = BrowserController.shared
                let result: String
                if let ref = call.string("ref") {
                    result = try await controller.click(ref: ref)
                } else if let selector = call.string("selector") {
                    result = try await controller.click(selector: selector)
                } else if let text = call.string("text") {
                    result = try await controller.clickByText(text)
                } else {
                    throw ToolError.missingArgument("selector or text")
                }
                if wait { await controller.waitForLoad(timeout: 6) }
                return captureAfter
                    ? result + "\n" + (try await BrowserTools.actionObservation(controller))
                    : result + "\n" + controller.pageInfo()
            }.value
        }
    }

    struct TypeTool: AgentTool {
        let name = "browser_type"
        let summary = "Type text into a form field by document-scoped ref or CSS selector"
        let risk = ToolRisk.execute
        let schemaText = """
            {"type":"object","properties":{
              "ref":{"type":"string","description":"Preferred: ref from browser_read what=elements"},
              "selector":{"type":"string"},
              "text":{"type":"string"},
              "capture_after":{"type":"boolean","default":true,"description":"Return a fresh bounded element observation after the action"}
            },"required":["text"]}
            """

        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
            guard let text = call.string("text") else { throw ToolError.missingArgument("text") }
            let captureAfter = BrowserTools.captureAfter(call)
            return try await Task { @MainActor in
                let controller = BrowserController.shared
                let result: String
                if let ref = call.string("ref") {
                    result = try await controller.type(text: text, intoRef: ref)
                } else if let selector = call.string("selector") {
                    result = try await controller.type(text: text, into: selector)
                } else {
                    throw ToolError.missingArgument("ref or selector")
                }
                return captureAfter
                    ? result + "\n" + (try await BrowserTools.actionObservation(controller))
                    : result + "\n" + controller.pageInfo()
            }.value
        }
    }

    struct EvalTool: AgentTool {
        let name = "browser_eval"
        let summary = "Evaluate a JavaScript expression on the open page and return the result"
        let risk = ToolRisk.execute
        let schemaText = """
            {"type":"object","properties":{
              "script":{"type":"string"},
              "capture_after":{"type":"boolean","default":false,"description":"Also return a fresh bounded element observation"}
            },"required":["script"]}
            """

        func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
            guard let script = call.string("script") else { throw ToolError.missingArgument("script") }
            let captureAfter = call.boolean("capture_after") ?? call.boolean("captureAfter") ?? false
            return try await Task { @MainActor in
                let controller = BrowserController.shared
                let result = try await controller.evaluate(script)
                let rendered = result.isEmpty ? "(empty result)" : String(result.prefix(12_000))
                return captureAfter
                    ? rendered + "\n" + (try await BrowserTools.actionObservation(controller))
                    : rendered
            }.value
        }
    }
}

extension ParsedToolCall {
    func integer(_ name: String) -> Int? {
        arguments.objectValue?[name]?.intValue
    }

    func boolean(_ name: String) -> Bool? {
        arguments.objectValue?[name]?.boolValue
    }
}
