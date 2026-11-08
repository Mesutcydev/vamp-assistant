import XCTest
@testable import BeetCode

final class OmniMediaTests: XCTestCase {
    func testPackedBonsaiCannotRouteToUpstreamQwen() {
        let upstream = ManagedInferenceRuntime(kind: .llamaCompatibility, revision: "upstream",
            executable: "upstream", models: ["renamed"], visionModels: [], architectures: ["qwen35"])
        let prism = ManagedInferenceRuntime(kind: .llamaCompatibility, revision: "prism",
            executable: "prism", models: [], visionModels: [], fileTypes: [141, 142, 143])
        for type in [141, 142, 143] {
            XCTAssertEqual(ManagedInferenceRuntime.selectGGUFCompatibility(modelID: "renamed",
                architecture: "qwen35", fileType: type, runtimes: [upstream, prism]), prism)
            XCTAssertNil(ManagedInferenceRuntime.selectGGUFCompatibility(modelID: "renamed",
                architecture: "qwen35", fileType: type, runtimes: [upstream]))
        }
        XCTAssertEqual(ManagedInferenceRuntime.selectGGUFCompatibility(modelID: "ordinary-qwen",
            architecture: "qwen35", fileType: 15, runtimes: [prism, upstream]), upstream)
    }

    func testMediaBytesAreSentAsTypedContentRatherThanFilePaths() throws {
        for kind in [OmniMediaRequest.Kind.audio, .video] {
            let input = OmniMediaRequest(kind: kind, prompt: "What happens?", data: Data([1, 2, 3]))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalOmniClient.mediaBody(input)) as? [String: Any])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
            XCTAssertEqual(parts.first?["type"] as? String, "input_\(kind.rawValue)")
            let media = try XCTUnwrap(parts.first?["input_\(kind.rawValue)"] as? [String: String])
            XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(media["data"])), input.data)
        }
    }

    func testCapabilitiesComeFromResidentRuntimeRatherThanModelName() throws {
        let models = Data("""
            {"data":[{"id":"arbitrary","architecture":{"input_modalities":["text","audio","video"],"output_modalities":["text","audio"]}}]}
            """.utf8)
        XCTAssertNoThrow(try LocalOmniClient.requireCapability(.audio, models: models))
        XCTAssertNoThrow(try LocalOmniClient.requireCapability(.video, models: models))
        XCTAssertNoThrow(try LocalOmniClient.requireCapability(.speech, models: models))
        XCTAssertThrowsError(try LocalOmniClient.requireCapability(.image, models: models))
        XCTAssertThrowsError(try LocalOmniClient.requireCapability(.speech, models: Data("{\"data\":[{}]}".utf8)))
    }

    func testSpeechRequestPreservesLanguageAndVoiceAndRejectsInvalidAudio() throws {
        let input = OmniMediaRequest(kind: .speech, prompt: "Merhaba", language: "tr", voice: "female")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalOmniClient.speechBody(input)) as? [String: Any])
        XCTAssertEqual(body["input"] as? String, "Merhaba")
        XCTAssertEqual(body["lang"] as? String, "tr")
        XCTAssertEqual(body["voice"] as? String, "female")
        XCTAssertEqual(body["response_format"] as? String, "wav")
        XCTAssertThrowsError(try LocalOmniClient.validateWAV(Data("{\"error\":\"failure\"}".utf8)))
        XCTAssertThrowsError(try LocalOmniClient.validateWAV(Data()))
    }

    func testSpeechCannotOverwriteOrEscapeWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.wav")
        try Data([42]).write(to: existing)
        let context = ToolContext(workspace: Workspace(root: root))
        for path in ["existing.wav", "../escape.wav"] {
            let call = ParsedToolCall(name: "generate_speech", arguments: .object(["path": .string(path), "text": .string("Hello")]), index: 0)
            do {
                _ = try await GenerateSpeechTool().execute(call, in: context)
                XCTFail("Unsafe destination was accepted")
            } catch {
                XCTAssertFalse(error is EngineError, "Destination must be rejected before inference")
            }
        }
        XCTAssertEqual(try Data(contentsOf: existing), Data([42]))
    }
}
