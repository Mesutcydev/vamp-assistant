import XCTest
@testable import BeetCode

final class CodexAppServerTests: XCTestCase {

    func testParsesResponseAndServerRequestMessages() throws {
        let responseValue = try LFJSONValue.decode(
            #"{"id":7,"result":{"account":{"type":"chatgpt","planType":"plus"}}}"#)
        let response = try XCTUnwrap(CodexServerMessage(value: responseValue))
        XCTAssertTrue(response.isResponse)
        XCTAssertEqual(response.id, 7)
        XCTAssertEqual(response.result?.objectValue?["account"]?.objectValue?["type"]?.stringValue, "chatgpt")

        let requestValue = try LFJSONValue.decode(
            #"{"id":8,"method":"item/commandExecution/requestApproval","params":{"itemId":"item-1"}}"#)
        let request = try XCTUnwrap(CodexServerMessage(value: requestValue))
        XCTAssertTrue(request.isServerRequest)
        XCTAssertFalse(request.isNotification)
        XCTAssertEqual(request.method, "item/commandExecution/requestApproval")

        let notificationValue = try LFJSONValue.decode(
            #"{"method":"item/agentMessage/delta","params":{"delta":"hello"}}"#)
        let notification = try XCTUnwrap(CodexServerMessage(value: notificationValue))
        XCTAssertTrue(notification.isNotification)
        XCTAssertEqual(notification.params?.objectValue?["delta"]?.stringValue, "hello")
    }

    func testExecutableDiscoveryHonorsAnExplicitExecutable() {
        let candidate = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: candidate) else { return }
        XCTAssertEqual(
            CodexAppServerClient.discoverExecutable(customPath: candidate)?.path,
            candidate)
    }

    func testSessionStoresOpaqueCodexThreadIdWithoutCredentials() throws {
        let record = SessionRecord(
            id: UUID(),
            title: "Codex account turn",
            createdAt: Date(),
            updatedAt: Date(),
            workspacePath: "/tmp/beetcode-codex-test",
            modelID: "openai-codex:gpt-5",
            messages: [],
            checkpoints: [],
            source: .app,
            schemaVersion: SessionRecord.currentSchemaVersion,
            codexThreadID: "thr_test",
            codexDynamicToolNames: ["browser_navigate", "computer_status"])
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: data)
        XCTAssertEqual(decoded.codexThreadID, "thr_test")
        XCTAssertEqual(decoded.codexDynamicToolNames, ["browser_navigate", "computer_status"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("refresh"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("access_token"))
    }

    func testModelListPageFollowsCursorAndKeepsHiddenLatestModels() throws {
        let first = try LFJSONValue.decode("""
            {"data":[{"id":"gpt-5.2-codex","displayName":"GPT-5.2 Codex","isDefault":true,"hidden":false}],"nextCursor":"page-2"}
            """)
        let second = try LFJSONValue.decode("""
            {"data":[{"id":"gpt-5.6-terra","displayName":"GPT-5.6 Terra","hidden":false},{"id":"gpt-5.4","displayName":"GPT-5.4","hidden":true,"supportedReasoningEfforts":[{"reasoningEffort":"high"}]}],"next_cursor":null}
            """)

        let page1 = CodexAppServerClient.modelListPage(first)
        XCTAssertEqual(page1.models.map(\.id), ["gpt-5.2-codex"])
        XCTAssertEqual(page1.nextCursor, "page-2")

        let page2 = CodexAppServerClient.modelListPage(second)
        XCTAssertEqual(page2.nextCursor, nil)
        XCTAssertEqual(Set(page2.models.map(\.id)), ["gpt-5.6-terra", "gpt-5.4"])
        XCTAssertTrue(page2.models.contains { $0.id == "gpt-5.4" && $0.hidden })
        XCTAssertEqual(
            page2.models.first { $0.id == "gpt-5.4" }?.supportedReasoningEfforts,
            ["high"])

        let sorted = CodexAppServerClient.sortedAccountModels(page1.models + page2.models)
        XCTAssertEqual(sorted.map(\.id), ["gpt-5.2-codex", "gpt-5.6-terra", "gpt-5.4"])
    }

    func testAccountCatalogSurfacesAstraFirstEvenWhenCodexOmitsIt() {
        let live = [
            CodexModelProfile(
                id: "gpt-5.2-codex",
                displayName: "GPT-5.2 Codex",
                description: "",
                defaultReasoningEffort: "medium",
                supportedReasoningEfforts: ["low", "medium", "high"],
                inputModalities: ["text"],
                isDefault: true,
                hidden: false),
        ]
        let merged = CodexAccountCatalog.merging(live: live)
        XCTAssertEqual(merged.first?.id, "gpt-6-astra")
        XCTAssertTrue(merged.contains { $0.id == "gpt-6-astra-pro" })
        XCTAssertTrue(merged.contains { $0.id == "gpt-5.2-codex" })
        XCTAssertTrue(CodexAccountCatalog.isLatest(modelID: "chatgpt|gpt-6-astra"))
        XCTAssertFalse(merged.contains { $0.id == "gpt-6-astra" && $0.hidden })
    }

    func testAccountCatalogKeepsLiveAstraMetadataAndUnhidesIt() {
        let live = CodexModelProfile(
            id: "gpt-6-astra",
            displayName: "Astra",
            description: "From Codex",
            defaultReasoningEffort: "max",
            supportedReasoningEfforts: ["low", "max"],
            inputModalities: ["text", "image"],
            isDefault: false,
            hidden: true)
        let merged = CodexAccountCatalog.merging(live: [live])
        let astra = merged.first { $0.id == "gpt-6-astra" }
        XCTAssertEqual(astra?.displayName, "Astra")
        XCTAssertEqual(astra?.description, "From Codex")
        XCTAssertEqual(astra?.defaultReasoningEffort, "max")
        XCTAssertEqual(astra?.supportedReasoningEfforts, ["low", "max"])
        XCTAssertEqual(astra?.hidden, false)
    }

    func testErrorsExplainWhichAppServerOperationFailed() {
        XCTAssertEqual(
            CodexAppServerError.timedOut("model/list").errorDescription,
            "Codex app-server timed out while handling model/list.")
        XCTAssertEqual(
            CodexAppServerError.malformedResponse("thread/resume").errorDescription,
            "Codex app-server returned an invalid response for thread/resume.")
    }

    @MainActor
    func testNativeControlToolsConvertToCodexDynamicFunctionSpecs() throws {
        let tools = AgentSessionController.sessionTools(
            computerControlEnabled: true,
            chatOnly: true)
        let specs = CodexAppServerClient.dynamicToolSpecs(for: tools)
        let objects = specs.compactMap(\.objectValue)
        let names = Set(objects.compactMap { $0["name"]?.stringValue })

        XCTAssertEqual(specs.count, tools.count)
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("computer_status"))
        XCTAssertTrue(names.contains("computer_key"))
        XCTAssertTrue(objects.allSatisfy { $0["type"]?.stringValue == "function" })
        XCTAssertTrue(objects.allSatisfy { $0["inputSchema"]?.objectValue != nil })
        XCTAssertFalse(names.contains("read_file"))
        XCTAssertFalse(names.contains("run_command"))
    }

    func testFinishedTerminationStatusIsNilWhileTheProcessIsAlive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["8"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        XCTAssertTrue(process.isRunning)
        XCTAssertNil(process.finishedTerminationStatus)
        process.terminate()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        XCTAssertNotNil(process.finishedTerminationStatus)
    }
}
