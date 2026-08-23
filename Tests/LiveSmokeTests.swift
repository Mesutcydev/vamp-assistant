import XCTest
@testable import BeetCode

/// LIVE end-to-end smoke test — NOT part of the hermetic suite contract.
/// Loads the real Qwythos GGUF through llama-server (exactly the app path:
/// GGUFEngine → RemoteLLMClient → AgentLoop) and runs a plan-mode turn with
/// a real file edit. Run manually:
///   xcodebuild test -scheme BeetCode -only-testing:BeetCodeTests/LiveSmokeTests
final class LiveSmokeTests: XCTestCase {

    func testQwen38ChatOnlyNonThinkingFastPath() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_QWEN38"] == "1" else {
            throw XCTSkip("Qwen3.8 chat smoke is opt-in (BEETCODE_LIVE_QWEN38=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwen3.8-9B-Q5_K_M")
        let modelFile = modelDir.appendingPathComponent("Qwen3.8-9B-Q5_K_M.gguf")
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw XCTSkip("Qwen3.8 9B Q5 GGUF model not installed")
        }

        let diskBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: modelFile.path)[.size]
                as? NSNumber)?.int64Value ?? 0)
        let engine = GGUFEngine()
        try await engine.load(
            directory: modelDir,
            modelID: "Qwen3.8-9B-Q5_K_M",
            diskBytes: diskBytes,
            contextSize: 8_192)
        defer { Task { await engine.unload() } }

        let started = Date()
        var answer = ""
        for try await chunk in engine.stream(
            adding: [
                ChatTurn(
                    role: .system,
                    content: "You are Beet Code in chat-only mode. Have a helpful, direct conversation."),
                ChatTurn(role: .user, content: "Reply with exactly: QWEN38_FAST_OK"),
            ],
            maxTokens: 256,
            temperature: 0)
        {
            answer += chunk
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(
            answer.trimmingCharacters(in: .whitespacesAndNewlines),
            "QWEN38_FAST_OK")
        XCTAssertFalse(answer.contains("<think>"))
        let stats = await engine.stats
        XCTAssertEqual(stats.acceleration, .standard)
        XCTAssertGreaterThan(stats.promptTokens, 0)
        XCTAssertGreaterThan(stats.generatedTokens, 0)
        XCTAssertEqual(stats.usageSerial, 1)
        print(
            "[qwen38-chat] PASS — visible answer in "
                + String(format: "%.3f", elapsed) + "s; "
                + "\(stats.promptTokens) prompt + \(stats.generatedTokens) completion tokens: "
                + String(format: "%.1f tok/s; ", stats.tokensPerSecond ?? 0)
                + answer)
        await engine.unload()
    }

    func testQwen38SemanticRebasePreservesExactPrefix() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_QWEN38"] == "1" else {
            throw XCTSkip("Qwen3.8 semantic-rebase smoke is opt-in (BEETCODE_LIVE_QWEN38=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwen3.8-9B-Q5_K_M")
        let modelFile = modelDir.appendingPathComponent("Qwen3.8-9B-Q5_K_M.gguf")
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw XCTSkip("Qwen3.8 9B Q5 GGUF model not installed")
        }

        let diskBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: modelFile.path)[.size]
                as? NSNumber)?.int64Value ?? 0)
        let engine = GGUFEngine()
        try await engine.load(
            directory: modelDir,
            modelID: "Qwen3.8-9B-Q5_K_M",
            diskBytes: diskBytes,
            contextSize: 8_192)
        defer { Task { await engine.unload() } }

        let system = ChatTurn(
            role: .system,
            content: "You are Beet Code in chat-only mode. Follow exact-answer instructions.")
        let stableContext = Array(
            repeating: "The stable semantic checkpoint marker is cobalt.",
            count: 320).joined(separator: " ")
        let firstUser = ChatTurn(
            role: .user,
            content: stableContext + "\nReply with exactly: CHECKPOINT_ONE")

        let firstStarted = Date()
        var first = ""
        for try await chunk in engine.stream(
            adding: [system, firstUser], maxTokens: 128, temperature: 0)
        {
            first += chunk
        }
        let firstElapsed = Date().timeIntervalSince(firstStarted)
        XCTAssertEqual(
            first.trimmingCharacters(in: .whitespacesAndNewlines),
            "CHECKPOINT_ONE")

        let rebased = [
            system,
            firstUser,
            ChatTurn(role: .assistant, content: "CHECKPOINT_ONE"),
            ChatTurn(role: .user, content: "Reply with exactly: CHECKPOINT_TWO"),
        ]
        let result = await engine.rebaseConversation(to: rebased)
        XCTAssertTrue(result.installedHistory)
        XCTAssertEqual(result.preservedCachePrefixTurns, 2)

        let started = Date()
        var second = ""
        for try await chunk in engine.stream(
            adding: [], maxTokens: 128, temperature: 0)
        {
            second += chunk
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(
            second.trimmingCharacters(in: .whitespacesAndNewlines),
            "CHECKPOINT_TWO")
        print(
            "[qwen38-checkpoint] PASS — 2 stable semantic turns; full prefix "
                + String(format: "%.3f", firstElapsed) + "s → cached continuation "
                + String(format: "%.3f", elapsed) + "s")
        await engine.unload()
    }

    func testQwen38NativeReadToolThroughAgentLoop() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_QWEN38_AGENT"] == "1" else {
            throw XCTSkip(
                "Qwen3.8 agent tool smoke is opt-in (BEETCODE_LIVE_QWEN38_AGENT=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwen3.8-9B-Q5_K_M")
        let modelFile = modelDir.appendingPathComponent("Qwen3.8-9B-Q5_K_M.gguf")
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw XCTSkip("Qwen3.8 9B Q5 GGUF model not installed")
        }

        let diskBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: modelFile.path)[.size]
                as? NSNumber)?.int64Value ?? 0)
        let engine = GGUFEngine()
        try await engine.load(
            directory: modelDir,
            modelID: "Qwen3.8-9B-Q5_K_M",
            diskBytes: diskBytes,
            contextSize: 8_192)
        defer { Task { await engine.unload() } }

        let workspace = TempWorkspace()
        workspace.write("VALUE_ALPHA", to: "value.txt")
        var config = AgentLoop.Configuration()
        config.maxTurns = 5
        config.maxTokensPerTurn = 512
        config.temperature = 0
        config.checkpointingEnabled = false
        config.contextWindowTokens = 8_192
        config.allowSubagents = false
        config.leanPrompt = true
        let task = "Read value.txt with the available file tool and report its exact contents. Do not guess."
        let loop = AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), WriteFileTool(), RunCommandTool()],
            permissions: PermissionGate(
                autoApproveEdits: false,
                autoApproveCommands: false,
                workspace: workspace.workspace),
            configuration: config,
            modelID: "Qwen3.8-9B-Q5_K_M",
            taskHint: task)

        let collector = EventCollector()
        let started = Date()
        let stream = await loop.run(userMessage: task)
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: 90)
        _ = await collection
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(collector.toolCalls().map(\.name), ["read_file"])
        guard case .completed(let answer)? = finish else {
            return XCTFail("Qwen agent run did not complete: \(String(describing: finish))")
        }
        XCTAssertTrue(answer.contains("VALUE_ALPHA"), answer)
        print(
            "[qwen38-agent] PASS — native read_file → verified answer in "
                + String(format: "%.3f", elapsed) + "s; " + answer)
        await engine.unload()
    }

    func testQwen38ReliabilityV2RepairsAndPassesSwiftTest() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_QWEN38_V2"] == "1" else {
            throw XCTSkip(
                "Qwen3.8 Reliability V2 smoke is opt-in (BEETCODE_LIVE_QWEN38_V2=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwen3.8-9B-Q5_K_M")
        let modelFile = modelDir.appendingPathComponent("Qwen3.8-9B-Q5_K_M.gguf")
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw XCTSkip("Qwen3.8 9B Q5 GGUF model not installed")
        }

        let workspace = TempWorkspace()
        workspace.write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "RepairKit",
            products: [.library(name: "RepairKit", targets: ["RepairKit"])],
            targets: [
                .target(name: "RepairKit"),
                .testTarget(name: "RepairKitTests", dependencies: ["RepairKit"]),
            ])
        """, to: "Package.swift")
        workspace.write("""
        public func repairedValue() -> Int {
            1
        }
        """, to: "Sources/RepairKit/Value.swift")
        workspace.write("""
        import Testing
        @testable import RepairKit

        @Test func repairedValueIsTwo() {
            #expect(repairedValue() == 2)
        }
        """, to: "Tests/RepairKitTests/ValueTests.swift")

        let diskBytes = Int64(
            (try FileManager.default.attributesOfItem(atPath: modelFile.path)[.size]
                as? NSNumber)?.int64Value ?? 0)
        let engine = GGUFEngine()
        try await engine.load(
            directory: modelDir,
            modelID: "Qwen3.8-9B-Q5_K_M",
            diskBytes: diskBytes,
            contextSize: 8_192)
        defer { Task { await engine.unload() } }

        var config = AgentLoop.Configuration()
        config.maxTurns = 8
        config.maxTokensPerTurn = 512
        config.temperature = 0
        config.checkpointingEnabled = false
        config.reliabilityV2 = true
        config.contextWindowTokens = 8_192
        config.allowSubagents = false
        config.leanPrompt = true
        let task = "Read Sources/RepairKit/Value.swift. Then use write_file to replace its complete contents with exactly: public func repairedValue() -> Int { 2 }. Then immediately call attempt_completion; Beet Code runs swift test automatically."
        let loop = AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), WriteFileTool(), BuildDiagnosticsTool()],
            permissions: PermissionGate(
                autoApproveEdits: true,
                autoApproveCommands: true,
                workspace: workspace.workspace),
            configuration: config,
            modelID: "Qwen3.8-9B-Q5_K_M",
            taskHint: task)

        let collector = EventCollector()
        let started = Date()
        let stream = await loop.run(userMessage: task)
        let collection = Task {
            for await event in stream {
                _ = collector.record(event)
                if case .awaitingApproval(let request) = event {
                    await loop.resolve(requestID: request.id, approved: true)
                }
            }
        }
        let finish = await collector.waitForFinish(timeout: 180)
        if finish == nil { await loop.cancel() }
        _ = await collection.value
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(collector.toolCalls().contains { $0.name == "read_file" })
        XCTAssertTrue(collector.toolCalls().contains { $0.name == "write_file" })
        XCTAssertTrue(collector.toolCalls().contains { $0.name == "build_diagnostics" })
        XCTAssertTrue(workspace.read("Sources/RepairKit/Value.swift")?.contains("2") == true)
        guard case .completed(let answer)? = finish else {
            return XCTFail("Qwen V2 run did not complete: \(String(describing: finish))")
        }
        XCTAssertTrue(answer.contains("Verified project checks passed"), answer)
        print(
            "[qwen38-v2] PASS — inspect → edit → swift test → verified completion in "
                + String(format: "%.3f", elapsed) + "s; " + answer)
        await engine.unload()
    }

    func testMLXPromptReuseAndKV8WithRealQwen35() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_MLX_EXPERIMENTS"] == "1" else {
            throw XCTSkip(
                "MLX experiment smoke is opt-in (BEETCODE_LIVE_MLX_EXPERIMENTS=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwen3.5-9B-abliterated-MLX-4bit")
        guard FileManager.default.fileExists(
            atPath: modelDir.appendingPathComponent("config.json").path)
        else { throw XCTSkip("Qwen3.5 9B MLX model not installed") }

        let diskBytes = (try? ModelStore.sizeOfDirectory(modelDir)) ?? 0
        let engine = MLXEngine(
            experimentalPromptCacheEnabled: true,
            experimentalQuantizedKVEnabled: true)
        try await engine.load(
            directory: modelDir,
            modelID: "qwen3.5-9b-4bit-mlx-experiments",
            diskBytes: diskBytes)

        // Cross the 512-token quantization onset with a deterministic prefix.
        let longPrefix = Array(repeating: "cache-prefix", count: 650)
            .joined(separator: " ")
        var first = ""
        for try await chunk in engine.stream(
            adding: [
                ChatTurn(role: .system, content: "Answer directly and briefly."),
                ChatTurn(
                    role: .user,
                    content: "Read this repeated prefix, then reply with CACHE_ONE. \(longPrefix)"),
            ],
            maxTokens: 24,
            temperature: 0)
        {
            first += chunk
        }
        XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let firstStats = await engine.stats

        // This is the exact delta shape AgentLoop sends: the visible assistant
        // echo followed by a new user/tool observation.
        let visibleFirst = MLXEngine.assistantEcho(from: first)
        var second = ""
        let incrementalStarted = Date()
        for try await chunk in engine.stream(
            adding: [
                ChatTurn(role: .assistant, content: visibleFirst),
                ChatTurn(role: .user, content: "Now reply with CACHE_TWO."),
            ],
            maxTokens: 24,
            temperature: 0)
        {
            second += chunk
        }
        let incrementalSeconds = Date().timeIntervalSince(incrementalStarted)
        XCTAssertFalse(second.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let incrementalStats = await engine.stats

        // A deterministic full replay of the same canonical transcript must
        // produce the same continuation. This catches a cache that is fast
        // but shifted by an assistant/EOS/template boundary.
        await engine.reset()
        var replayedSecond = ""
        let replayStarted = Date()
        for try await chunk in engine.stream(
            adding: [
                ChatTurn(role: .system, content: "Answer directly and briefly."),
                ChatTurn(
                    role: .user,
                    content: "Read this repeated prefix, then reply with CACHE_ONE. \(longPrefix)"),
                ChatTurn(role: .assistant, content: visibleFirst),
                ChatTurn(role: .user, content: "Now reply with CACHE_TWO."),
            ],
            maxTokens: 24,
            temperature: 0)
        {
            replayedSecond += chunk
        }
        let replaySeconds = Date().timeIntervalSince(replayStarted)
        let replayStats = await engine.stats
        XCTAssertEqual(
            MLXEngine.assistantEcho(from: second),
            MLXEngine.assistantEcho(from: replayedSecond),
            "incremental MLX cache output must match deterministic full replay")

        let stats = await engine.stats
        XCTAssertTrue(stats.mlxPromptCacheActive)
        XCTAssertTrue(stats.mlxQuantizedKVActive)
        let incrementalLabel = String(format: "%.2f", incrementalSeconds)
        let replayLabel = String(format: "%.2f", replaySeconds)
        let cachedDecodeLabel = String(
            format: "%.1f", incrementalStats.tokensPerSecond ?? 0)
        let replayDecodeLabel = String(
            format: "%.1f", replayStats.tokensPerSecond ?? 0)
        print(
            "[mlx-experiments] PASS — cached \(incrementalLabel)s, "
                + "full replay \(replayLabel)s; "
                + "prompt tokens \(firstStats.promptTokens) first / "
                + "\(incrementalStats.promptTokens) cached / \(replayStats.promptTokens) replay; "
                + "decode \(cachedDecodeLabel) cached / \(replayDecodeLabel) replay tok/s; "
                + "first: \(visibleFirst.prefix(80)); second: \(second.prefix(80))")
        await engine.unload()
    }

    func testNGramWithRealQwen25GGUF() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_NGRAM"] == "1" else {
            throw XCTSkip("N-gram smoke is opt-in (BEETCODE_LIVE_NGRAM=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwen2.5-7B-Instruct-abliterated-Q4_K_M")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("Qwen2.5 7B GGUF model not installed")
        }

        let engine = GGUFEngine(experimentalNGramEnabled: true)
        try await engine.load(
            directory: modelDir,
            modelID: "Qwen2.5-7B-Instruct-abliterated-Q4_K_M",
            diskBytes: 4_683_073_568,
            contextSize: 4_096)
        defer { Task { await engine.unload() } }

        let stats = await engine.stats
        XCTAssertEqual(stats.acceleration, .ngram)

        var answer = ""
        let stream = engine.stream(
            adding: [ChatTurn(
                role: .user,
                content: "Repeat this exact line three times: red orange yellow green blue indigo violet one two three four five six seven eight nine ten.")],
            maxTokens: 160,
            temperature: 0)
        for try await chunk in stream {
            answer += chunk
        }
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("[ngram-smoke] PASS — response: \(answer.prefix(160))")
    }

    func testDFlashWithRealQwen35GGUF() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_DFLASH"] == "1" else {
            throw XCTSkip("DFlash smoke is opt-in (BEETCODE_LIVE_DFLASH=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwythos-9B-Claude-Mythos-5-1M-MTP-Q5_K_M")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("Qwen3.5 9B GGUF model not installed")
        }

        let engine = GGUFEngine(experimentalDFlashEnabled: true)
        try await engine.load(
            directory: modelDir,
            modelID: "Qwythos-9B-Claude-Mythos-5-1M-MTP-Q5_K_M",
            diskBytes: 6_726_528_608,
            contextSize: 4_096)
        defer { Task { await engine.unload() } }

        let stats = await engine.stats
        XCTAssertEqual(stats.acceleration, .dflash,
                       "the compatible Qwen3.5 9B load must use DFlash")

        var answer = ""
        let stream = engine.stream(
            adding: [ChatTurn(role: .user, content: "Reply with exactly: DFLASH_OK")],
            maxTokens: 24,
            temperature: 0)
        for try await chunk in stream {
            answer += chunk
        }
        XCTAssertFalse(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("[dflash-smoke] PASS — response: \(answer.prefix(120))")
    }

    func testPlanModeEditWithRealQwythos() async throws {
        // Opt-in only: the hermetic suite must never load real weights.
        // Run with BEETCODE_LIVE_SMOKE=1 in the environment.
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("live smoke is opt-in (BEETCODE_LIVE_SMOKE=1)")
        }
        let modelDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/BeetCode/Models/Qwythos-9B-Claude-Mythos-5-1M-MTP-Q5_K_M")
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw XCTSkip("Qwythos model not installed")
        }

        let workspace = TempWorkspace()
        workspace.write("say hello to the world\n", to: "note.txt")

        // 1. Engine: real llama-server launch (MTP included when the header
        //    advertises it) through the real admission gate.
        let engine = GGUFEngine()
        let loadStart = Date()
        try await engine.load(
            directory: modelDir,
            modelID: "qwythos-smoke",
            diskBytes: 6_726_528_608)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        print("[smoke] model loaded in \(String(format: "%.1f", loadSeconds))s")
        defer { Task { await engine.unload() } }

        // 2. Loop in PLAN mode — the exact user-reported broken path.
        var config = AgentLoop.Configuration()
        config.maxTurns = 8
        config.maxTokensPerTurn = 2048
        config.temperature = 0.6
        config.planMode = true
        config.checkpointingEnabled = false
        config.showReasoning = true
        let permissions = PermissionGate(
            autoApproveEdits: true,
            autoApproveCommands: false,
            workspace: workspace.workspace)
        let loop = AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), WriteFileTool(), ApplyPatchTool()],
            permissions: permissions,
            configuration: config,
            modelID: "qwythos-smoke")

        // 3. Drive the event stream: approve the plan the moment it is
        //    proposed, record milestones, enforce a hard deadline.
        let milestones = Milestones()
        let stream = await loop.run(
            userMessage: "In note.txt, change the word hello to hi.")
        let consumer = Task {
            for await event in stream {
                switch event {
                case .planProposed(let plan):
                    await milestones.mark("planProposed")
                    print("[smoke] plan proposed (\(plan.count) chars) — approving")
                    await loop.resolvePlan(approved: true)
                case .toolCallStarted(let invocation):
                    await milestones.mark("tool:\(invocation.name)")
                    print("[smoke] tool started: \(invocation.name)")
                case .assistantMessage(let text):
                    await milestones.mark("assistantMessage")
                    print("[smoke] assistant message: \(text.prefix(120))")
                case .protocolError(let message):
                    print("[smoke] protocol notice: \(message.prefix(120))")
                case .finished(let reason):
                    await milestones.mark("finished:\(reason)")
                    print("[smoke] finished: \(reason)")
                default:
                    break
                }
            }
        }

        let deadline = Date().addingTimeInterval(220)
        while Date() < deadline {
            if await milestones.seen("finished:") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        if await !milestones.seen("finished:") {
            print("[smoke] deadline hit — cancelling")
            await loop.cancel()
        }
        _ = await consumer.result

        // 4. Assertions: the plan gate fired, the edit executed for real,
        //    and the run terminated without an engine error.
        let seen = await milestones.all
        XCTAssertTrue(seen.contains("planProposed"),
                      "plan mode must produce a plan card — milestones: \(seen)")
        let content = workspace.read("note.txt") ?? ""
        XCTAssertTrue(content.contains("hi"),
                      "the edit must land on disk — note.txt is: \(content)")
        XCTAssertTrue(seen.contains { $0.hasPrefix("finished:") },
                      "the run must finish — milestones: \(seen)")
        XCTAssertFalse(seen.contains("finished:engineError"),
                       "no engine error — milestones: \(seen)")
        let tools = seen.filter { $0.hasPrefix("tool:") }
        print("[smoke] PASS — tools used: \(tools)")
    }
}

/// Tiny async-safe milestone recorder for the smoke driver.
private actor Milestones {
    private var list: [String] = []
    func mark(_ value: String) { list.append(value) }
    func seen(_ prefix: String) -> Bool { list.contains { $0.hasPrefix(prefix) } }
    var all: [String] { list }
}
