import Foundation
import XCTest
@testable import BeetCode

/// Drives ACPClient against a tiny python agent speaking ACP v1 over stdio:
/// handshake, session, streamed updates, a permission round-trip (string
/// request id), and the prompt's stop reason.
final class ACPHarnessTests: XCTestCase {

    private var tempDir: URL!
    private var agentScript: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vamp-acp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        agentScript = tempDir.appendingPathComponent("fake_acp_agent.py")
        let script = """
        import sys, json
        def send(o): print(json.dumps(o), flush=True)
        def update(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": u}})
        prompt_id = None
        mcp = []
        model = "m1"
        for line in sys.stdin:
            msg = json.loads(line)
            method = msg.get("method")
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1,
                      "agentCapabilities": {"promptCapabilities": {"image": True}}}})
            elif method == "session/new":
                mcp = msg["params"]["mcpServers"]
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s1", "configOptions": [
                    {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "m1",
                     "options": [{"group": "g", "name": "G", "options": [
                        {"value": "m1", "name": "One"}, {"value": "m2", "name": "Two"}]}]}]}})
            elif method == "session/set_config_option":
                model = msg["params"]["value"]
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"configOptions": []}})
            elif method == "session/prompt":
                prompt_id = msg["id"]
                images = [b for b in msg["params"]["prompt"] if b["type"] == "image"]
                update({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": json.dumps(
                    {"images": len(images), "mcp": mcp, "model": model})}})
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "po"}})
                update({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ng"}})
                update({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "ls", "kind": "execute", "status": "pending"})
                send({"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": {
                    "sessionId": "s1", "toolCall": {"toolCallId": "t1"},
                    "options": [{"optionId": "no", "name": "Reject", "kind": "reject_once"},
                                {"optionId": "yes", "name": "Allow", "kind": "allow_once"}]}})
            elif msg.get("id") == "perm-1":
                allowed = msg["result"]["outcome"].get("optionId") == "yes"
                update({"sessionUpdate": "tool_call_update", "toolCallId": "t1",
                        "status": "completed" if allowed else "failed",
                        "content": [{"type": "content", "content": {"type": "text", "text": "file.txt"}}]})
                send({"jsonrpc": "2.0", "id": prompt_id, "result": {"stopReason": "end_turn"}})
        """
        try? script.write(to: agentScript, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRunsATurnWithAPermissionRoundTrip() async throws {
        let client = ACPClient(harness: ACPHarness(id: "fake", name: "Fake", command: "python3 \(agentScript.path)"))
        try await client.start()
        let session = try await client.newSession(cwd: tempDir, mcpServers: [
            "fs": MCPServerConfig(command: "python3", args: ["-V"], env: ["K": "v"]),
            "web": MCPServerConfig(url: "https://example.com/mcp")
        ])
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.models.map(\.id), ["m1", "m2"], "grouped select options flatten")
        XCTAssertEqual(session.currentModelID, "m1")
        XCTAssertEqual(session.modelConfigID, "model")
        try await client.setModel("m2", in: session)

        let events = await client.events()
        let collector = Task { () -> [ACPMessage] in
            var seen: [ACPMessage] = []
            for await message in events {
                seen.append(message)
                if let id = message.id {
                    let options = message.params["options"]?.arrayValue ?? []
                    await client.respond(id: id, result: ACPClient.permissionResult(
                        options: options, approved: true, always: false))
                }
            }
            return seen
        }
        let stopReason = try await client.prompt(sessionID: session.id, text: "hi", images: [
            ChatImage(data: Data([1, 2, 3]), mimeType: "image/png", name: "a.png")
        ])
        await client.stop()
        let seen = await collector.value

        XCTAssertEqual(stopReason, "end_turn")
        let updates = seen.compactMap { $0.params["update"]?.objectValue }
        let text = updates.filter { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" }
            .compactMap { $0["content"]?.objectValue?["text"]?.stringValue }.joined()
        XCTAssertEqual(text, "pong")
        let thought = updates.first { $0["sessionUpdate"]?.stringValue == "agent_thought_chunk" }
        let seenByAgent = try XCTUnwrap(thought?["content"]?.objectValue?["text"]?.stringValue)
        let report = try XCTUnwrap(try LFJSONValue.decode(seenByAgent).objectValue)
        XCTAssertEqual(report["images"]?.intValue, 1)
        XCTAssertEqual(report["model"]?.stringValue, "m2")
        let mcp = try XCTUnwrap(report["mcp"]?.arrayValue)
        XCTAssertEqual(mcp.count, 1, "HTTP servers are withheld from an agent without http MCP support")
        XCTAssertEqual(mcp.first?.objectValue?["name"]?.stringValue, "fs")
        XCTAssertTrue(mcp.first?.objectValue?["command"]?.stringValue?.hasPrefix("/") == true, "stdio commands go out absolute")
        let finished = try XCTUnwrap(updates.first { $0["sessionUpdate"]?.stringValue == "tool_call_update" })
        XCTAssertEqual(finished["status"]?.stringValue, "completed", "the allow option id must reach the agent")
        XCTAssertEqual(ACPClient.toolOutput(finished), "file.txt")
        XCTAssertEqual(ACPClient.toolName(kind: "execute"), "run_command")
    }

    func testPermissionMappingAndMissingHarness() async throws {
        let options: [LFJSONValue] = [
            .object(["optionId": .string("a1"), "kind": .string("allow_once")]),
            .object(["optionId": .string("aa"), "kind": .string("allow_always")]),
            .object(["optionId": .string("r1"), "kind": .string("reject_once")])
        ]
        func chosen(_ approved: Bool, _ always: Bool) -> String? {
            ACPClient.permissionResult(options: options, approved: approved, always: always)
                .objectValue?["outcome"]?.objectValue?["optionId"]?.stringValue
        }
        XCTAssertEqual(chosen(true, false), "a1")
        XCTAssertEqual(chosen(true, true), "aa")
        XCTAssertEqual(chosen(false, false), "r1")
        XCTAssertEqual(ACPClient.permissionResult(options: [], approved: true, always: false),
                       ACPClient.cancelledPermission)

        let missing = ACPClient(harness: ACPHarness(id: "x", name: "Missing", command: "vamp-no-such-harness-xyz"))
        do {
            try await missing.start()
            XCTFail("a missing harness must fail to start")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Missing exited"), error.localizedDescription)
        }
    }

    func testRegistryParsingAndLegacyModels() throws {
        let registry = """
        {"agents": [
          {"id": "auggie", "name": "Auggie CLI", "distribution": {"npx": {"package": "@augmentcode/auggie@0.36.0",
            "args": ["--acp"], "env": {"AUGMENT_DISABLE_AUTO_UPDATE": "1"}}}},
          {"id": "fast", "name": "fast-agent", "distribution": {"uvx": {"package": "fast-agent-acp==0.10.1", "args": ["-x"]}}},
          {"id": "cursor", "name": "Cursor", "distribution": {"binary": {"darwin-aarch64": {"archive": "x",
            "cmd": "./dist-package/cursor-agent", "args": ["acp"]}}}},
          {"id": "linux-only", "name": "Linux", "distribution": {"binary": {"linux-x86_64": {"cmd": "./l"}}}},
          {"id": "claude-acp", "name": "Claude Agent", "distribution": {"npx": {"package": "a@1"}}}
        ]}
        """
        let parsed = ACPHarness.parseRegistry(Data(registry.utf8))
        XCTAssertEqual(parsed.map(\.command), [
            "AUGMENT_DISABLE_AUTO_UPDATE=1 npx -y @augmentcode/auggie@0.36.0 --acp",
            "uvx fast-agent-acp==0.10.1 -x",
            "cursor-agent acp"
        ], "no darwin build and preset duplicates are dropped")
        XCTAssertEqual(parsed.first?.id, "registry:auggie")

        var session = ACPSessionInfo(id: "s", models: [])
        ACPClient.applyModels(from: ["models": .object([
            "currentModelId": .string("b"),
            "availableModels": .array([.object(["modelId": .string("a"), "name": .string("A")]),
                                       .object(["modelId": .string("b"), "name": .string("B")])])
        ])], to: &session)
        XCTAssertEqual(session.models.map(\.name), ["A", "B"])
        XCTAssertEqual(session.currentModelID, "b")
        XCTAssertNil(session.modelConfigID, "legacy state switches through session/set_model")
    }
}
