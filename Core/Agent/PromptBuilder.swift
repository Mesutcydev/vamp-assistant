import Foundation

/// Builds the system prompt that teaches the model the tool protocol. Works
/// with any model regardless of native function-calling support — the model
/// emits fenced ```tool JSON blocks that ToolParser extracts.
enum PromptBuilder {

    static func systemPrompt(
        tools: [any AgentTool],
        workspace: Workspace,
        repoIndex: RepoIndex? = nil,
        memorySection: String? = nil,
        projectInstructions: String? = nil,
        projectPolicy: String? = nil,
        workspaceHistory: String? = nil,
        agentPrompt: String? = nil,
        planMode: Bool = false,
        goalMode: Bool = false,
        outputStyle: ProjectPolicy.OutputStyle = .normal,
        contextWindowTokens: Int? = nil,
        responseReserveTokens: Int = 4096,
        leanPrompt: Bool = false,
        chatOnly: Bool = false
    ) -> String {
        if chatOnly {
            return chatOnlyPrompt(
                tools: tools.filter { isChatOnlyTool($0.name) },
                outputStyle: outputStyle,
                contextWindowTokens: contextWindowTokens,
                responseReserveTokens: responseReserveTokens)
        }

        var sections: [String] = []
        sections.append("""
        You are Vamp Assistant using the optional Code capability inside the user's \
        project directory: \(workspace.root.path)

        You accomplish tasks by using tools, one per message. Think briefly, then \
        act. Prefer reading before writing. Verify your work by running commands \
        when useful. Be concise in prose — spend your effort on correct tool calls.
        """)

        if planMode {
            sections.append("""
            # Plan mode

            You are in PLAN mode. Your FIRST reply must be a concise plan of
            what you will do — reading, edits, and commands you intend to run.
            Do NOT call any tool yet. Wait for the user to approve the plan.
            Once approved, execute the plan step by step with tools.
            """)
        }

        // Small local GGUF models are much more reliable when the lean
        // prompt contains one direct instruction surface. Goal mode is still
        // tracked by the controller, but its long-form prompt block can make
        // Llama-family models echo the tool protocol instead of answering.
        if goalMode && !leanPrompt {
            sections.append("""
            # Goal mode

            Stay focused on the user's complete goal. After the plan is
            approved, keep inspecting, editing, verifying, and correcting until
            the requested outcome is actually complete. Do not stop after a
            partial change; use attempt_completion only when the goal is done
            or a concrete blocker needs the user's input.
            """)
        }

        sections.append(outputStylePrompt(outputStyle))

        sections.append("""
        # Reliable execution contract

        Before editing, inspect the target file plus its closest definitions,
        callers, and tests. Make the smallest change that satisfies the task.
        After any workspace mutation, run the narrowest relevant test or build.
        If it fails, use the exact diagnostics to repair the change and verify
        again. Do not repeat an unchanged failing action. Review the final diff
        for unintended files. Never claim success until the latest changes have
        passed an appropriate check; report the check and any remaining risk.
        """)

        if !leanPrompt,
           let agentPrompt,
           !agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            sections.append("# Active agent profile\n\n\(bounded(agentPrompt, characters: 12_000))")
        }

        // Put the small, exact capability map before the much larger schema
        // catalog. On a tight context window, fitPrompt may shorten the
        // catalog; the model must still know which app surfaces exist and
        // which verification loop to choose. This is useful in lean mode too,
        // where only the compact coding registry is actually enabled.
        if let guidance = capabilityGuidance(tools: tools) {
            sections.append(guidance)
        }

        sections.append("""
        # Tool protocol

        To call a tool, emit exactly one fenced block:

        ```tool
        {"name": "<tool>", "arguments": { … }}
        ```

        Rules:
        - One tool call per reply. After each call you receive its output as the \
        next message, then continue.
        - Use only the listed tools with valid JSON arguments.
        - If the user asks you to create, edit, fix, build, or test something, \
        perform the work with tools before describing it. Never print proposed \
        file contents as prose and then claim the task is complete.
        - Keep each tool call small enough to finish valid JSON. For a large new \
        file, use `apply_patch` with an empty SEARCH block to create the first \
        chunk, then append focused chunks in later calls.
        - Commands run without an interactive terminal. Never start `sudo` or an \
        installer that waits for a password. Check `/usr/local/bin` and \
        `/opt/homebrew/bin` before concluding a tool is missing; if administrator \
        authorization is genuinely required, report the blocker instead of \
        claiming completion.
        - For a GitHub repository install request, do the complete workflow: \
        validate the URL, clone it into the workspace (or use the existing checkout), \
        read its README and package metadata, run the documented non-interactive \
        install/build command after approval, and verify the resulting command or \
        app. Do not stop after opening the repository or merely describe the steps. \
        If the README asks for a password, sudo, or interactive prompt, stop at that \
        exact blocker and explain it clearly.
        - When the task is fully complete, call `attempt_completion` with a short \
        summary of what changed.
        - If you need information only the user can provide, call `ask_user`.
        """)

        if !leanPrompt {
            // Project conventions and durable facts outrank bulky argument
            // schemas. Keep them ahead of the catalog so a constrained prompt
            // cannot silently discard the user's operating rules.
            if let projectInstructions, !projectInstructions.isEmpty {
                sections.append("# Project instructions (AGENTS.md / CLAUDE.md)\n\n\(bounded(projectInstructions, characters: 8_000))")
            }

            if let projectPolicy, !projectPolicy.isEmpty {
                sections.append("# Project policy\n\n\(bounded(projectPolicy, characters: 4_000))")
            }

            if let memorySection {
                sections.append("# Memory\n\n\(bounded(memorySection, characters: 6_000))")
            }

            sections.append("""
            # Conventions for editing files

            Prefer `apply_patch` with SEARCH/REPLACE blocks for edits. SEARCH text \
            must match the file exactly, character-for-character, including \
            indentation. Include just enough surrounding lines to make the match \
            unique. Use `write_file` only for new files or complete rewrites. You \
            must read a file before editing it.
            """)
        }

        var toolDocs: [String] = []
        for tool in tools.sorted(by: { $0.name < $1.name }) {
            toolDocs.append("## \(tool.name) — \(tool.summary)\n\(tool.schemaText)")
        }
        sections.append("# Tool argument schemas\n\n" + toolDocs.joined(separator: "\n\n"))

        if !leanPrompt {
            // Bounded repository context: the model sees the project shape and
            // per-file summaries instead of raw file dumps. Summaries survive
            // compaction because they live in the system prompt.
            if let repoIndex, !repoIndex.entries.isEmpty {
                sections.append(
                    "# Workspace structure (bounded index)\n\n\(bounded(repoIndex.render, characters: 8_000))")
            }

            // Workspace history: what earlier sessions in THIS folder were about
            // — BeetCode's own and chats imported from Claude / Codex / Cursor.
            // Bounded digest; like memory it survives compaction in the prompt.
            if let workspaceHistory, !workspaceHistory.isEmpty {
                sections.append("# Earlier work in this workspace\n\n\(bounded(workspaceHistory, characters: 4_000))")
            }
        } else {
            // Large local models on a memory-constrained Mac cannot afford a
            // full workspace index, project history, or broad tool registry
            // in every prefill. Keep the direct-answer path explicit.
            sections.append("""
            # Lightweight local mode

            Answer ordinary questions directly when no file inspection or edit
            is needed. Do not call a tool just to be helpful. For coding work,
            use only the compact tool list above and keep each step focused.
            For a short request such as "Reply with exactly X", return exactly
            the requested text. Do not add greetings, identity statements,
            "Task complete", or a conclusion unless the user asks for them.
            Preserve the user's requested Markdown, line breaks, and code
            indentation in the answer.
            """)
        }

        let prompt = sections.joined(separator: "\n\n")
        guard let contextWindowTokens else { return prompt }

        // A model's context contains both this system prompt and the next
        // reply. Keep a response reserve so a large repository index cannot
        // make the first request fail before a tool or plan is produced.
        let promptBudget = max(
            8_000,
            (contextWindowTokens - max(1_024, responseReserveTokens) - 512) * 3)
        return fitPrompt(sections, maxCharacters: promptBudget)
    }

    /// Chat-only can still operate app-owned browser and opt-in computer-use
    /// surfaces. Project, file, command, memory, MCP, and hook capabilities
    /// remain unavailable because there is no workspace confinement boundary.
    static func isChatOnlyTool(_ name: String) -> Bool {
        name.hasPrefix("browser_") || name.hasPrefix("computer_")
            || name == "tailscale_status" || name == "disk_space_status"
            || name == "mac_system_status"
    }

    private static func chatOnlyPrompt(
        tools: [any AgentTool],
        outputStyle: ProjectPolicy.OutputStyle,
        contextWindowTokens: Int?,
        responseReserveTokens: Int
    ) -> String {
        var sections = [
            """
            You are Vamp Assistant in project-free assistant mode. Have a helpful, direct
            conversation with the user. No project folder is connected. You
            cannot inspect or change project files, run shell commands, use
            project memory, or claim workspace access. If the user asks for
            project work, explain that they need to open a project folder.
            """,
            outputStylePrompt(outputStyle),
        ]
        if tools.isEmpty {
            sections.append("No tools are available in this chat.")
        } else {
            if let guidance = capabilityGuidance(tools: tools) {
                sections.append(guidance)
            }
            sections.append("""
                # Tool protocol

                To call an available tool, emit exactly one fenced block:

                ```tool
                {"name": "<tool>", "arguments": { … }}
                ```

                Use one tool per reply. After any browser or computer action,
                observe the result again before claiming success. Only the
                tools listed below are available in chat-only mode.
                """)
            if tools.contains(where: { $0.name == "disk_space_status" }) {
                sections.append("""
                    # Direct Mac status checks

                    For disk/free-space questions call `disk_space_status`.
                    For Tailscale state call `tailscale_status`. For macOS,
                    installed memory, processors, uptime, or thermal state call
                    `mac_system_status`. Never use `computer_status`, System
                    Settings, screenshots, or UI navigation for these facts.
                    """)
            }
            let toolDocs = tools.sorted(by: { $0.name < $1.name }).map {
                "## \($0.name) — \($0.summary)\n\($0.schemaText)"
            }
            sections.append("# Tool argument schemas\n\n" + toolDocs.joined(separator: "\n\n"))
        }
        let prompt = sections.joined(separator: "\n\n")
        guard let contextWindowTokens else { return prompt }
        let promptBudget = max(
            8_000,
            (contextWindowTokens - max(1_024, responseReserveTokens) - 512) * 3)
        return fitPrompt(sections, maxCharacters: promptBudget)
    }

    private static func outputStylePrompt(_ style: ProjectPolicy.OutputStyle) -> String {
        let readability = """
        Format every answer as readable Markdown. Separate paragraphs with a
        blank line. When presenting three or more facts, options, steps, or
        examples, put each item on its own bullet or numbered line. Use short
        headings or bold labels when they make the structure clearer. Never
        concatenate headings, list items, or sentences without whitespace.
        """
        switch style {
        case .concise:
            return """
            # Response style

            Keep the final answer concise. State what changed, the verification
            result, and any blocker or next action. Do not repeat the user's
            request or narrate routine tool calls.

            \(readability)
            """
        case .normal:
            return """
            # Response style

            Use a balanced final answer: summarize the meaningful changes,
            mention verification, and explain any remaining caveat in plain
            language. Keep routine tool narration out of the final response.

            \(readability)
            """
        case .detailed:
            return """
            # Response style

            Give a detailed final answer with the important design decisions,
            files or surfaces affected, verification performed, and any
            remaining caveat. Stay organized and avoid repeating raw logs.

            \(readability)
            """
        }
    }

    /// Keeps supplementary context useful without allowing one generated
    /// section (especially a repository index) to crowd out the protocol.
    private static func bounded(_ text: String, characters: Int) -> String {
        guard text.count > characters else { return text }
        return String(text.prefix(characters))
            + "\n…[section shortened to preserve the model context budget]"
    }

    /// Trims only at section boundaries whenever possible. The required
    /// system/tool sections are built first, while later workspace details
    /// are the first content sacrificed under a small local context window.
    private static func fitPrompt(_ sections: [String], maxCharacters: Int) -> String {
        var kept: [String] = []
        var used = 0
        for section in sections {
            let separator = kept.isEmpty ? 0 : 2
            let remaining = maxCharacters - used - separator
            guard remaining > 0 else { break }
            if section.count <= remaining {
                kept.append(section)
                used += separator + section.count
            } else {
                let marker = "\n…[remaining workspace context omitted to preserve the reply budget]"
                let prefixLength = max(0, remaining - marker.count)
                if prefixLength > 0 {
                    kept.append(String(section.prefix(prefixLength)) + marker)
                }
                break
            }
        }
        return kept.joined(separator: "\n\n")
    }

    /// A compact, task-oriented map of the exact capabilities enabled for
    /// this run. It deliberately precedes the larger schema catalog so it
    /// survives prompt fitting on smaller context windows. Every tool name in
    /// the map is filtered through the registry; unavailable sibling tools
    /// are never advertised by implication.
    static func capabilityGuidance(tools: [any AgentTool]) -> String? {
        let names = Set(tools.map(\.name))
        guard !names.isEmpty else { return nil }

        func enabled(_ candidates: [String]) -> [String] {
            candidates.filter { names.contains($0) }
        }

        func toolList(_ tools: [String]) -> String {
            tools.map { "`\($0)`" }.joined(separator: ", ")
        }

        var lines: [String] = [
            "This map is generated from the tools enabled for this run. Use these capabilities when the task calls for them; do not assume an unlisted sibling tool exists. Detailed argument schemas follow."
        ]
        var classified: Set<String> = []

        func add(_ label: String, tools candidates: [String], guidance: String) {
            let available = enabled(candidates)
            guard !available.isEmpty else { return }
            classified.formUnion(available)
            lines.append("- **\(label)** — \(toolList(available)). \(guidance)")
        }

        add("Inspect the workspace",
            tools: ["read_file", "list_directory", "search", "find_files", "glob"],
            guidance: "Read and search before editing; use file discovery instead of guessing paths.")
        add("Edit the workspace",
            tools: ["apply_patch", "write_file", "move_file"],
            guidance: "Prefer exact patches for existing files and verify the result.")
        add("Run and verify",
            tools: ["run_command", "background_process", "background_status", "build_diagnostics"],
            guidance: names.contains("background_process")
                ? "Use detected checks for code changes; put long-running dev servers in `background_process`."
                : "Use the listed command/check surface after code changes and inspect its result.")
        add("Read the public web",
            tools: ["web_fetch"],
            guidance: names.contains("browser_navigate")
                ? "Use for bounded page text or API output; use `browser_navigate` when interaction or layout matters."
                : "Use for bounded page text or API output.")
        add("In-app browser",
            tools: ["browser_navigate", "browser_read", "browser_click", "browser_type", "browser_scroll", "browser_eval", "browser_screenshot"],
            guidance: names.contains("browser_navigate") && names.contains("browser_read")
                ? "For web UI, navigate → browser_read what=elements → act with a fresh ref. Actions capture a bounded fresh observation by default; never reuse a ref after it changes."
                : "Use only the listed browser operations and observe again after any interaction.")
        add("Built-in iOS Simulator",
            tools: ["sim_build_run", "sim_list_devices", "sim_boot_device", "sim_launch_app", "sim_tap", "sim_swipe", "sim_type", "sim_describe", "sim_screenshot"],
            guidance: names.contains("sim_build_run")
                ? "Prefer `sim_build_run` for build → install → launch → screenshot → describe, then fix and repeat."
                : "Use only the listed simulator controls and re-observe after interaction.")
        add("Mac computer control",
            tools: ["computer_request_access", "computer_status", "computer_ui_tree", "computer_screenshot", "computer_click", "computer_type", "computer_key", "computer_scroll"],
            guidance: names.contains("computer_status")
                ? "Check `computer_status` first. If a required permission is missing, call approval-gated `computer_request_access` with only accessibility or screenRecording and a task-specific reason. Then observe with `computer_ui_tree` and prefer fresh refs for clicks, typing, and scrolling."
                : "Always observe → act → re-observe; prefer fresh element refs because coordinates and old refs go stale after UI changes.")
        add("Vision",
            tools: ["describe_image"],
            guidance: "Use for screenshots and visual assets when pixel appearance matters.")
        add("Create and deliver Apple apps",
            tools: ["create_macos_app", "create_ios_app", "macos_build_run", "apple_ship"],
            guidance: names.contains("apple_ship")
                ? "Scaffold only when needed, get the app launching, inspect it, and use `apple_ship` only after verification. Never invent signing secrets."
                : "Scaffold only when needed, get the app launching when that tool is listed, and inspect the result.")
        add("Delegate focused work",
            tools: ["task"],
            guidance: "Choose research, implement, verify, or review; implementation is isolated by default. Do not nest subagents.")
        add("Durable project memory",
            tools: ["memory_add", "memory_delete"],
            guidance: "Store only stable project facts that will help future sessions.")
        add("Finish or ask",
            tools: ["ask_user", "attempt_completion"],
            guidance: "Ask only for information the user must supply; complete only after requested verification succeeds or a concrete blocker is reported.")

        // MCP and future tools still become discoverable immediately, even
        // before Beet Code gains a purpose-built routing sentence for them.
        let extensions = tools
            .filter { !classified.contains($0.name) }
            .sorted { $0.name < $1.name }
        if !extensions.isEmpty {
            let visible = extensions.prefix(12).map { tool -> String in
                let summary = tool.summary
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let compactSummary = summary.count > 120
                    ? String(summary.prefix(120)) + "…"
                    : summary
                return "`\(tool.name)` — \(compactSummary)"
            }
            let remainder = extensions.count - visible.count
            let suffix = remainder > 0
                ? "; plus \(remainder) more in the argument schemas"
                : ""
            lines.append("- **Connected extensions** — \(visible.joined(separator: "; "))\(suffix).")
        }

        lines.append("Writes, commands, and UI/network actions may pause for approval. Request them normally and let Vamp Assistant enforce the boundary; never claim success without observing the result.")
        return "# Runtime capability map\n\n" + lines.joined(separator: "\n")
    }

    /// Extracts the concatenated reasoning blocks from raw generation. Local
    /// chat templates and remote providers use several equivalent markers;
    /// normalizing them here keeps the UI and the agent loop on one contract.
    static func extractingThinking(_ text: String) -> String? {
        let blocks = thinkingBlocks(in: text, includeUnterminated: false)
        guard !blocks.isEmpty else { return nil }
        return joiningThinkingBlocks(blocks)
    }

    /// Streaming counterpart of `extractingThinking`: it also returns the
    /// currently open block so the live reasoning surface can update before a
    /// provider closes its thought section.
    static func extractingThinkingIncludingOpen(_ text: String) -> String {
        joiningThinkingBlocks(thinkingBlocks(in: text, includeUnterminated: true))
    }

    /// True when generation is currently inside a reasoning delimiter. A
    /// complete block is not considered open, so an answer can stream without
    /// leaving the “working” state permanently lit.
    static func hasOpenThinkingBlock(_ text: String) -> Bool {
        for pair in reasoningTagPairs {
            var cursor = text.startIndex
            while let open = text.range(
                of: pair.open,
                options: [.caseInsensitive],
                range: cursor..<text.endIndex)
            {
                let search = open.upperBound..<text.endIndex
                guard let close = text.range(
                    of: pair.close,
                    options: [.caseInsensitive],
                    range: search)
                else { return true }
                cursor = close.upperBound
            }
        }
        if hasOpenChannelThinkingBlock(text) { return true }
        let markerCount = text.components(separatedBy: "思考").count - 1
        return markerCount % 2 == 1
    }

    /// Strips reasoning blocks before the text is parsed for tool calls or
    /// shown as a final answer. This also removes an unterminated block when a
    /// model hits its output ceiling halfway through its private channel.
    static func strippingThinking(_ text: String) -> String {
        var result = text
        result = strippingChannelThinking(result)
        for pair in reasoningTagPairs {
            let open = NSRegularExpression.escapedPattern(for: pair.open)
            let close = NSRegularExpression.escapedPattern(for: pair.close)
            result = result.replacingOccurrences(
                of: "(?is)\(open)[\\s\\S]*?\(close)",
                with: "",
                options: .regularExpression)
            if let range = result.range(
                of: "(?is)\(open)[\\s\\S]*$",
                options: .regularExpression) {
                result.removeSubrange(range)
            }
        }
        // Qwen-style Chinese reasoning marker (思考): some uncensored/Chinese
        // finetunes delimit the reasoning preamble with 思考 … 思考 instead of
        // <think> tags. A complete pair proves the delimiter convention, so
        // the whole preamble through the closing marker is hidden. A lone
        // marker is ambiguous (the word also means "thinking" in ordinary
        // prose), so only the tail from the marker on is hidden — preceding
        // text stays visible and the message can never vanish entirely.
        // Each iteration removes at least one marker, so the loop is bounded.
        while let first = result.range(of: "思考") {
            let rest = result[first.upperBound...]
            if let close = rest.range(of: "思考") {
                result.removeSubrange(result.startIndex..<close.upperBound)
            } else {
                result.removeSubrange(first.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes chat-template control tokens that can leak when a local model
    /// uses a different generation wrapper than the one it was fine-tuned
    /// with. The answer itself is left untouched so Markdown, code fences,
    /// indentation, and line breaks retain their original structure.
    static func strippingModelControlTokens(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?is)<\|start_header_id\|>\s*(?:system|user|assistant|tool)\s*<\|end_header_id\|>"#,
            #"(?is)<\|im_start\|>\s*(?:system|user|assistant|tool)\s*"#,
            #"<\|(?:eot_id|end_of_text|im_end|im_start|end|begin_of_text|start_of_turn|end_of_turn)\|>"#,
            #"<\|(?:start_header_id|end_header_id|assistant|user|system|tool)\|>"#,
            #"</?s>"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One cleanup path for every engine before text reaches the transcript
    /// or the persisted session. Tool syntax is handled separately because it
    /// must remain available to the agent loop's parser.
    static func cleaningGeneratedText(_ text: String) -> String {
        strippingModelControlTokens(strippingThinking(text))
    }

    /// Extracts the small, unambiguous exact-answer requests commonly used to
    /// smoke-test a local model. Some instruct finetunes answer those prompts
    /// conversationally (for example, "I'll."), so the agent can enforce the
    /// user's explicit contract without changing ordinary prose generation.
    static func exactRequestedAnswer(in request: String) -> String? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let prefixes = [
            "reply with exactly ",
            "respond with exactly ",
            "output exactly ",
            "return exactly ",
        ]
        guard let prefix = prefixes.first(where: { lowercased.hasPrefix($0) }) else {
            return nil
        }

        var answer = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The period in "Reply with exactly OK." is sentence punctuation for
        // the instruction, not part of the requested token. Remove it before
        // handling the equally common "and nothing else" suffix.
        if let last = answer.last, ".!?".contains(last) {
            answer.removeLast()
            answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nothingElse = " and nothing else"
        if answer.lowercased().hasSuffix(nothingElse) {
            answer.removeLast(nothingElse.count)
            answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !answer.isEmpty, answer.count <= 512 else { return nil }
        return answer
    }

    private static let reasoningTagPairs: [(open: String, close: String)] = [
        ("<think>", "</think>"),
        ("<thinking>", "</thinking>"),
        ("<reasoning>", "</reasoning>"),
        ("<analysis>", "</analysis>"),
        ("<|thinking|>", "<|/thinking|>"),
        ("<|assistant_thought|>", "<|/assistant_thought|>"),
        ("[thinking]", "[/thinking]"),
    ]

    private struct ThinkingBlock {
        let offset: Int
        let endOffset: Int
        let text: String
    }

    private static func thinkingBlocks(in text: String, includeUnterminated: Bool) -> [ThinkingBlock] {
        var located: [ThinkingBlock] = []
        for pair in reasoningTagPairs {
            var cursor = text.startIndex
            while let open = text.range(
                of: pair.open,
                options: [.caseInsensitive],
                range: cursor..<text.endIndex)
            {
                let search = open.upperBound..<text.endIndex
                if let close = text.range(
                    of: pair.close,
                    options: [.caseInsensitive],
                    range: search)
                {
                    let rawValue = String(text[open.upperBound..<close.lowerBound])
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        located.append(ThinkingBlock(
                            offset: text.distance(from: text.startIndex, to: open.lowerBound),
                            endOffset: text.distance(from: text.startIndex, to: close.upperBound),
                            text: rawValue))
                    }
                    cursor = close.upperBound
                } else {
                    if includeUnterminated {
                        let rawValue = String(text[open.upperBound...])
                        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty {
                            located.append(ThinkingBlock(
                                offset: text.distance(from: text.startIndex, to: open.lowerBound),
                                endOffset: text.count,
                                text: rawValue))
                        }
                    }
                    break
                }
            }
        }

        located.append(contentsOf: channelThinkingBlocks(in: text, includeUnterminated: includeUnterminated))

        // Chinese models use a paired 思考 delimiter. Keep it in the same
        // ordered channel as XML-style markers.
        var markerRanges: [Range<String.Index>] = []
        var markerCursor = text.startIndex
        while let range = text.range(of: "思考", range: markerCursor..<text.endIndex) {
            markerRanges.append(range)
            markerCursor = range.upperBound
        }
        var markerIndex = 0
        while markerIndex + 1 < markerRanges.count {
            let start = markerRanges[markerIndex].upperBound
            let end = markerRanges[markerIndex + 1].lowerBound
            let rawValue = String(text[start..<end])
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                located.append(ThinkingBlock(
                    offset: text.distance(from: text.startIndex, to: markerRanges[markerIndex].lowerBound),
                    endOffset: text.distance(from: text.startIndex, to: markerRanges[markerIndex + 1].upperBound),
                    text: rawValue))
            }
            markerIndex += 2
        }
        if includeUnterminated, markerIndex < markerRanges.count {
            let rawValue = String(text[markerRanges[markerIndex].upperBound...])
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                located.append(ThinkingBlock(
                    offset: text.distance(from: text.startIndex, to: markerRanges[markerIndex].lowerBound),
                    endOffset: text.count,
                    text: rawValue))
            }
        }

        return located.sorted { $0.offset < $1.offset }
    }

    /// Provider streams often encode each reasoning delta as its own complete
    /// `<think>…</think>` pair. Those pairs are adjacent in the accumulated
    /// wire text, so treating them as separate paragraphs turns a thought into
    /// one word per line. Keep real separated reasoning blocks readable, but
    /// join adjacent provider fragments as one continuous trace.
    private static func joiningThinkingBlocks(_ blocks: [ThinkingBlock]) -> String {
        var result = ""
        var previous: ThinkingBlock?

        for block in blocks {
            let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.isEmpty {
                result = trimmed
            } else if let previous, block.offset == previous.endOffset {
                result = appendingReasoningFragment(block.text, to: result)
            } else {
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    + "\n\n"
                    + trimmed
            }
            previous = block
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendingReasoningFragment(_ fragment: String, to text: String) -> String {
        guard !text.isEmpty, !fragment.isEmpty else { return text + fragment }
        if text.last?.isWhitespace == true || fragment.first?.isWhitespace == true {
            return text + fragment
        }
        if let first = fragment.first,
           String(first).rangeOfCharacter(from: .punctuationCharacters) != nil {
            return text + fragment
        }
        return text + " " + fragment
    }

    /// Some OpenAI-compatible gateways preserve the model's internal
    /// channel protocol instead of translating it to `<think>` tags. The
    /// analysis channel is private model work; the final channel is the
    /// answer. Keep the markers out of both surfaces while retaining the
    /// analysis text for the reasoning card.
    private static let analysisChannel = "<|channel|>analysis<|message|>"
    private static let finalChannel = "<|channel|>final<|message|>"
    private static let channelEnd = "<|end|>"

    private static func channelThinkingBlocks(
        in text: String,
        includeUnterminated: Bool
    ) -> [ThinkingBlock] {
        var result: [ThinkingBlock] = []
        var cursor = text.startIndex
        while let open = text.range(
            of: analysisChannel,
            options: [.caseInsensitive],
            range: cursor..<text.endIndex)
        {
            let search = open.upperBound..<text.endIndex
            let final = text.range(of: finalChannel, options: [.caseInsensitive], range: search)
            let end = text.range(of: channelEnd, options: [.caseInsensitive], range: search)
            let boundary: Range<String.Index>? = [final, end]
                .compactMap { $0 }
                .min { $0.lowerBound < $1.lowerBound }

            if let boundary {
                let rawValue = String(text[open.upperBound..<boundary.lowerBound])
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    result.append(ThinkingBlock(
                        offset: text.distance(from: text.startIndex, to: open.lowerBound),
                        endOffset: text.distance(from: text.startIndex, to: boundary.upperBound),
                        text: rawValue))
                }
                cursor = boundary.upperBound
            } else {
                if includeUnterminated {
                    let rawValue = String(text[open.upperBound...])
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        result.append(ThinkingBlock(
                            offset: text.distance(from: text.startIndex, to: open.lowerBound),
                            endOffset: text.count,
                            text: rawValue))
                    }
                }
                break
            }
        }
        return result
    }

    private static func hasOpenChannelThinkingBlock(_ text: String) -> Bool {
        guard let open = text.range(
            of: analysisChannel,
            options: [.caseInsensitive],
            range: text.startIndex..<text.endIndex)
        else { return false }
        let search = open.upperBound..<text.endIndex
        let final = text.range(of: finalChannel, options: [.caseInsensitive], range: search)
        let end = text.range(of: channelEnd, options: [.caseInsensitive], range: search)
        guard let boundary = [final, end].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound })
        else { return true }
        // A later analysis channel can reopen the state after a completed
        // channel; recurse on the suffix rather than treating the first one
        // as authoritative.
        let suffix = String(text[boundary.upperBound...])
        return hasOpenChannelThinkingBlock(suffix)
    }

    private static func strippingChannelThinking(_ text: String) -> String {
        var result = text
        var cursor = result.startIndex
        while let open = result.range(
            of: analysisChannel,
            options: [.caseInsensitive],
            range: cursor..<result.endIndex)
        {
            let search = open.upperBound..<result.endIndex
            let final = result.range(of: finalChannel, options: [.caseInsensitive], range: search)
            let end = result.range(of: channelEnd, options: [.caseInsensitive], range: search)
            let boundary: Range<String.Index>? = [final, end]
                .compactMap { $0 }
                .min { $0.lowerBound < $1.lowerBound }
            guard let boundary else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
                break
            }
            if boundary == final {
                // Keep the final channel's answer, then remove its marker in
                // the cleanup pass below.
                result.removeSubrange(open.lowerBound..<boundary.lowerBound)
                cursor = open.lowerBound
            } else {
                result.removeSubrange(open.lowerBound..<boundary.upperBound)
                cursor = open.lowerBound
            }
        }
        result = result.replacingOccurrences(
            of: finalChannel,
            with: "",
            options: [.caseInsensitive])
        result = result.replacingOccurrences(
            of: channelEnd,
            with: "",
            options: [.caseInsensitive])
        return result
    }
}

/// Selects the smallest useful tool surface for one user task. The executor
/// still owns the complete permission-filtered registry; this router only
/// controls what the model sees in its prompt/native function catalog.
/// Unknown or vague tasks fail open to the full registry so routing can never
/// make an unusual workflow impossible.
enum ToolRouter {

    enum EvidenceRequirement: Equatable {
        case none
        case tool
        case mutation
    }

    static func select(
        from tools: [any AgentTool],
        for task: String,
        preserveFullRegistry: Bool = false
    ) -> [any AgentTool] {
        // Chat-only already has a deliberately tiny, permission-filtered
        // registry. Keep both browser and computer families available so a
        // mixed control request cannot be narrowed to only one family.
        if preserveFullRegistry { return tools }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !tools.isEmpty else { return tools }

        let lower = trimmed.lowercased()
        let words = tokens(in: lower)
        let available = Set(tools.map(\.name))
        var selected = Set<String>()
        var recognized = false

        func has(_ candidates: Set<String>) -> Bool {
            !words.isDisjoint(with: candidates)
        }

        func include(_ names: [String]) {
            selected.formUnion(names.filter { available.contains($0) })
        }

        // Control flow is always available. It is tiny, and omitting it can
        // strand a model after otherwise successful work.
        include(["ask_user", "attempt_completion"])

        let mutating = has(mutationWords)
        let inspecting = mutating || has(inspectionWords)
        let verifying = mutating || has(verificationWords)

        if inspecting {
            recognized = true
            include(["read_file", "search", "find_files"])
            if has(["directory", "folder", "list", "structure", "tree"]) {
                include(["list_directory"])
            }
        }
        if mutating {
            include(["apply_patch", "write_file"])
            if has(["move", "rename"]) { include(["move_file"]) }
        }
        if verifying {
            recognized = true
            include(["run_command"])
            if has(["build", "compile", "diagnose", "test", "tests", "xcode", "swift"]) {
                include(["build_diagnostics"])
            }
        }
        if has(["background", "daemon", "server", "serve", "watch"]) {
            recognized = true
            include(["background_process", "background_status"])
        }

        let webWords: Set<String> = [
            "api", "docs", "documentation", "github", "http", "https", "internet",
            "online", "research", "url", "web",
        ]
        if has(webWords) || lower.contains("www.") || lower.contains("://") {
            recognized = true
            include(["web_fetch"])
        }

        let browserWords: Set<String> = [
            "browser", "button", "click", "dom", "form", "page", "rendered",
            "site", "website",
        ]
        if has(browserWords) {
            recognized = true
            include([
                "browser_navigate", "browser_read", "browser_screenshot",
                "browser_click", "browser_type", "browser_scroll", "browser_eval",
            ])
        }

        let simulatorWords: Set<String> = [
            "iphone", "ipad", "ios", "simulator", "simctl",
        ]
        if has(simulatorWords) {
            recognized = true
            include(["sim_build_run", "sim_describe", "sim_screenshot"])
            if has(["boot", "gesture", "interact", "launch", "swipe", "tap", "type"]) {
                include([
                    "sim_list_devices", "sim_boot_device", "sim_launch_app",
                    "sim_tap", "sim_swipe", "sim_type",
                ])
            }
        }

        let computerWords: Set<String> = [
            "desktop", "finder", "keynote", "mac", "macos", "screen", "system",
        ]
        if has(computerWords) && has(["click", "control", "interact", "open", "operate", "type"]) {
            recognized = true
            include([
                "computer_status", "computer_ui_tree", "computer_screenshot",
                "computer_click", "computer_type", "computer_key", "computer_scroll",
            ])
        }

        if has(["design", "image", "photo", "screenshot", "visual"]) {
            recognized = true
            include(["describe_image"])
        }

        if has(["scaffold"]) || (has(["create", "new"]) && has(["app", "application"])) {
            recognized = true
            include(["create_macos_app", "create_ios_app", "macos_build_run"])
        }
        if has(["archive", "device", "distribution", "ipa", "ship", "sign", "testflight", "upload"]) {
            recognized = true
            include(["apple_ship", "macos_build_run"])
        }
        if has(["delegate", "parallel", "subagent"]) {
            recognized = true
            include(["task"])
        }
        if has(["forget", "memory", "remember"]) {
            recognized = true
            include(["memory_add", "memory_delete"])
        }

        // Connected tools have arbitrary names. Include a bounded number only
        // when their name/summary meaningfully overlaps the task.
        let extensionMatches = tools.compactMap { tool -> (String, Int)? in
            guard !knownToolNames.contains(tool.name) else { return nil }
            let haystack = tokens(in: tool.name + " " + tool.summary)
            let overlap = words.intersection(haystack).count
            let exact = lower.contains(tool.name.lowercased()) ? 4 : 0
            let score = overlap + exact
            return score >= 2 ? (tool.name, score) : nil
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }
        if !extensionMatches.isEmpty {
            recognized = true
            include(extensionMatches.prefix(4).map(\.0))
        }

        guard recognized else { return tools }
        return tools.filter { selected.contains($0.name) }
    }

    /// Classifies whether a project request needs observable execution before
    /// the agent may call it complete. Direct imperatives and concrete project
    /// diagnostics require evidence; ordinary knowledge questions do not.
    static func evidenceRequirement(for task: String) -> EvidenceRequirement {
        let lower = task.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty, PromptBuilder.exactRequestedAnswer(in: task) == nil else {
            return .none
        }
        let words = tokens(in: lower)
        let first = lower.split { !$0.isLetter && !$0.isNumber }.first.map(String.init) ?? ""
        let directivePrefixes = [
            "please ", "can you ", "could you ", "would you ", "will you ",
            "i want you to ", "i need you to ", "need you to ", "let's ",
            "lets ", "go ahead", "proceed",
        ]
        let directAction = actionWords.contains(first)
            || directivePrefixes.contains(where: lower.hasPrefix)

        if directAction && !words.isDisjoint(with: mutationWords) {
            return .mutation
        }
        if directAction && !words.isDisjoint(with: toolActionWords) {
            return .tool
        }

        let projectSpecific = !words.isDisjoint(with: projectWords)
        let diagnostic = !words.isDisjoint(with: inspectionWords.union(verificationWords))
        if projectSpecific && diagnostic { return .tool }
        return .none
    }

    static func requiresBrowserEvidence(for task: String) -> Bool {
        let lower = task.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = tokens(in: lower)
        return !words.isDisjoint(with: browserEvidenceWords)
            || lower.contains("in-app browser")
    }

    private static let knownToolNames: Set<String> = [
        "read_file", "write_file", "move_file", "list_directory", "search",
        "find_files", "glob", "web_fetch", "background_process", "background_status",
        "apply_patch", "run_command", "build_diagnostics", "create_macos_app",
        "create_ios_app", "macos_build_run", "apple_ship", "sim_list_devices",
        "sim_boot_device", "sim_launch_app", "sim_tap", "sim_swipe", "sim_type",
        "sim_describe", "sim_screenshot", "describe_image", "sim_build_run",
        "browser_read", "browser_screenshot", "browser_navigate", "browser_click",
        "browser_type", "browser_scroll", "browser_eval", "computer_status", "computer_ui_tree",
        "computer_screenshot", "computer_click", "computer_type", "computer_key",
        "computer_scroll", "task", "memory_add", "memory_delete", "ask_user",
        "attempt_completion", "tailscale_status", "disk_space_status",
        "mac_system_status",
    ]

    private static let mutationWords: Set<String> = [
        "add", "adjust", "build", "change", "clean", "convert", "correct",
        "create", "delete", "edit", "enable", "fix", "implement", "improve",
        "install", "make", "migrate", "modify", "optimize", "polish", "refactor",
        "remove", "rename", "replace", "rewrite", "support", "update", "upgrade",
        "write",
    ]
    private static let inspectionWords: Set<String> = [
        "analyze", "audit", "check", "code", "debug", "diagnose", "explain",
        "file", "find", "inspect", "investigate", "issue", "locate", "project",
        "repo", "repository", "review", "source", "trace",
    ]
    private static let verificationWords: Set<String> = [
        "benchmark", "build", "compile", "diagnose", "lint", "profile", "run",
        "test", "tests", "verify",
    ]
    private static let toolActionWords: Set<String> = inspectionWords
        .union(verificationWords)
        .union(["browse", "click", "navigate", "open", "preview", "read", "search", "serve"])
    private static let actionWords: Set<String> = mutationWords.union(toolActionWords)
    private static let projectWords: Set<String> = [
        "app", "build", "code", "error", "file", "folder", "page", "project",
        "repo", "repository", "site", "source", "test", "tests", "website",
    ]
    private static let browserEvidenceWords: Set<String> = [
        "browser", "page", "preview", "render", "rendered", "site", "website",
    ]

    private static func tokens(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
