import XCTest
@testable import BeetCode

final class ToolParserTests: XCTestCase {

    func testFencedToolBlock() {
        let text = """
        Let me look at that file.
        ```tool
        {"name": "read_file", "arguments": {"path": "Sources/App.swift"}}
        ```
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.string("path"), "Sources/App.swift")
    }

    func testMultipleFencedCalls() {
        let text = """
        ```tool
        {"name": "list_files", "arguments": {"path": "."}}
        ```
        ```tool
        {"name": "search", "arguments": {"pattern": "TODO", "glob": "*.swift"}}
        ```
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["list_files", "search"])
    }

    func testQwenToolCallTags() {
        let text = #"""
        I'll check the build.
        <tool_call>
        {"name": "run_command", "arguments": {"command": "swift build"}}
        </tool_call>
        """#
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "run_command")
    }

    func testStrippingToolCallsRemovesTheWholeWrapper() {
        let text = #"""
        I'll check the build.
        <tool_call>
        {"name": "run_command", "arguments": {"command": "swift build"}}
        </tool_call>
        Done.
        """#
        XCTAssertEqual(ToolParser.strippingCalls(from: text), "I'll check the build.\n\nDone.")
    }

    func testStrippingEmptyToolCallWrapperRemovesProtocolNoise() {
        let text = "The answer is ready.\n<tool_call>\n\n</tool_call>"
        XCTAssertEqual(ToolParser.strippingCalls(from: text), "The answer is ready.")
    }

    func testOpenAIEnvelope() {
        let text = #"""
        {"tool_calls": [{"function": {"name": "read_file", "arguments": "{\"path\": \"a.txt\"}"}}]}
        """#
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "read_file")
        // Arguments arrived as a JSON *string* and must be coerced to an object.
        XCTAssertEqual(call.string("path"), "a.txt")
    }

    func testTolerantJSONSingleQuotesAndTrailingComma() {
        let text = """
        ```tool
        {'name': 'apply_patch', 'arguments': {'path': 'main.py', 'diff': 'x',}}
        ```
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "apply_patch")
        XCTAssertEqual(call.string("path"), "main.py")
    }

    func testBareJSONObjectFallback() {
        let text = #"""
        I should read the config first: {"name": "read_file", "arguments": {"path": "config.json"}}
        """#
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "read_file")
    }

    func testNoToolCallInPlainProse() {
        let calls = ToolParser.parse("The build succeeded with no warnings. Great!")
        XCTAssertTrue(calls.isEmpty)
    }

    func testMalformedCallIsSkippedNotFatal() {
        let text = """
        ```tool
        {"name": "read_file", "arguments": {"path": broken json here
        ```
        ```tool
        {"name": "list_files", "arguments": {}}
        ```
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["list_files"])
    }

    func testClosedMalformedToolWrapperRequestsRepair() {
        let text = "```tool\n{\"arguments\": {}}\n```"
        XCTAssertNotNil(ToolParser.malformedCallReason(text))
        XCTAssertTrue(ToolParser.parse(text).isEmpty)
    }

    func testOrdinaryJSONIsNotAProtocolFailure() {
        let text = "Here is the config: {\"theme\": \"dark\"}."
        XCTAssertNil(ToolParser.malformedCallReason(text))
        XCTAssertTrue(ToolParser.parse(text).isEmpty)
    }

    func testAlternatesKeyNames() {
        for key in ["arguments", "args", "parameters", "input"] {
            let text = "```tool\n{\"name\": \"t\", \"\(key)\": {\"x\": 1}}\n```"
            let calls = ToolParser.parse(text)
            XCTAssertEqual(calls.count, 1, "failed for key \(key)")
            guard let call = calls.first else { continue }
            XCTAssertEqual(call.int("x"), 1)
        }
    }

    func testToolResultBlockNotMistakenForCall() {
        let text = """
        ```tool_result
        {"output": "file contents here", "ok": true}
        ```
        """
        let calls = ToolParser.parse(text)
        XCTAssertTrue(calls.isEmpty)
    }

    func testDuplicateCallsCollapsed() {
        let text = """
        ```tool
        {"name": "list_files", "arguments": {"path": "."}}
        ```
        <tool_call>{"name": "list_files", "arguments": {"path": "."}}</tool_call>
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
    }
}

final class ToolCallTextTests: XCTestCase {

    /// The wire serializer (engines that receive structured tool-call events)
    /// must emit text the parser reads back as the same call.
    func testSerializeParsesBack() {
        let text = ToolCallText.serialize(
            name: "read_file",
            argumentsJSON: #"{"path":"Sources/App.swift"}"#)
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.count, 1)
        guard let call = calls.first else { return }
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(call.string("path"), "Sources/App.swift")
    }

    func testSerializeEmptyArguments() {
        let calls = ToolParser.parse(ToolCallText.serialize(name: "build_diagnostics", argumentsJSON: "{}"))
        XCTAssertEqual(calls.map(\.name), ["build_diagnostics"])
    }

    func testSerializeEscapesQuotesInName() {
        let calls = ToolParser.parse(ToolCallText.serialize(name: #"we"ird"#, argumentsJSON: "{}"))
        XCTAssertEqual(calls.first?.name, #"we"ird"#)
    }

    func testHermesNameOnFirstLine() {
        let text = """
        <tool_call>
        read_file
        {"path": "A.swift"}
        </tool_call>
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.string("path"), "A.swift")
    }

    func testLlamaFunctionEqualsWrapper() {
        let text = #"<function=ask_user>{"question":"Which port?"}</function>"#
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["ask_user"])
        XCTAssertEqual(calls.first?.askUserQuestion(), "Which port?")
    }

    func testInvokeParameterWrapper() {
        let text = #"<invoke name="read_file"><parameter name="path">A.swift</parameter></invoke>"#
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.string("path"), "A.swift")
    }

    func testToolNameKeyAndFlatArguments() {
        let fence = "\u{60}\u{60}\u{60}"
        let text = "\(fence)tool\n{\"tool_name\":\"ask_user\",\"question\":\"Ship it?\"}\n\(fence)"
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["ask_user"])
        XCTAssertEqual(calls.first?.askUserQuestion(), "Ship it?")
        XCTAssertEqual(calls.first?.askUserChoices(), [])
    }

    func testAskUserStringArgumentsAndChoices() {
        let fence = "\u{60}\u{60}\u{60}"
        let text = "\(fence)tool\n{\"name\":\"ask_user\",\"arguments\":\"Which theme?\",\"choices\":[\"dark\",\"light\"]}\n\(fence)"
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.first?.askUserQuestion(), "Which theme?")
        XCTAssertEqual(calls.first?.askUserChoices(), ["dark", "light"])
    }

    func testHermesAskUserPlainQuestion() {
        let text = """
        <tool_call>
        ask_user
        Which port should the server use?
        </tool_call>
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["ask_user"])
        XCTAssertEqual(calls.first?.askUserQuestion(), "Which port should the server use?")
        XCTAssertEqual(calls.first?.argumentsJSON, "\"Which port should the server use?\"")
    }

    func testXMLTaggedArgumentsInsideToolCall() {
        let text = """
        <tool_call>
        read_file
        <path>A.swift</path>
        </tool_call>
        """
        let calls = ToolParser.parse(text)
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.string("path"), "A.swift")
    }
}

final class TolerantJSONTests: XCTestCase {

    func testCommentsStripped() {
        let raw = """
        {
          // the name
          "name": "x", /* block */
          "arguments": {},
        }
        """
        let value = TolerantJSON.value(from: raw)
        XCTAssertEqual(value?.objectValue?["name"]?.stringValue, "x")
    }

    func testRawNewlineInsideStringEscaped() {
        let raw = #"""
        {"a": "line1
        line2"}
        """#
        let value = TolerantJSON.value(from: raw)
        XCTAssertEqual(value?.objectValue?["a"]?.stringValue, "line1\nline2")
    }

    func testUnrecoverableInputReturnsNil() {
        XCTAssertNil(TolerantJSON.value(from: "not json at all"))
        XCTAssertNil(TolerantJSON.value(from: "{'unterminated: 'x}"))
    }
}
