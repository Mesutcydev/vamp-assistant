import XCTest
@testable import BeetCode

final class ManagedInferenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func executable(in root: URL, name: String = "server") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testManifestRejectsMissingAndEscapedExecutables() throws {
        let root = try directory()
        let outside = try directory()
        let file = try executable(in: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: file)
        let good = try executable(in: root)
        let candidates = ["missing", "../server", file.path, "escape", good.lastPathComponent]
        let entries = candidates.map {
            ManagedInferenceRuntime(kind: .omlx, revision: "test", executable: $0, models: ["example"], visionModels: [])
        }
        try JSONEncoder().encode(ManagedInferenceRuntime.Manifest(version: 1, runtimes: entries))
            .write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ManagedInferenceRuntime.installed(root: root).map(\.executable), ["server"])
    }

    func testUnknownManifestVersionIsNotExecuted() throws {
        let root = try directory()
        _ = try executable(in: root)
        let runtime = ManagedInferenceRuntime(kind: .omlx, revision: "test", executable: "server", models: ["example"], visionModels: [])
        try JSONEncoder().encode(ManagedInferenceRuntime.Manifest(version: 2, runtimes: [runtime]))
            .write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertTrue(ManagedInferenceRuntime.installed(root: root).isEmpty)
    }

    func testFallbackPreservesImagesContextAndUnload() async throws {
        let root = try directory()
        let fallback = FakeLLMEngine(supportsImageInput: true)
        fallback.stubbedContextWindow = 8192
        fallback.enqueue(texts: ["image received"])
        let engine = ManagedMLXEngine(fallback: fallback, runtimeRoot: root, resolveRuntime: { _, _ in nil })
        try await engine.load(directory: root, modelID: "standard-mlx", diskBytes: 1)
        let images = [ChatImage(data: Data([1, 2, 3]), mimeType: "image/png", name: "test")]
        var reply = ""
        for try await chunk in engine.stream(adding: [.init(role: .user, content: "Read this", images: images)],
                                             maxTokens: 32, temperature: 0) { reply += chunk }
        let supportsImages = await engine.supportsImageInput
        let context = await engine.effectiveContextWindow
        XCTAssertTrue(supportsImages)
        XCTAssertEqual(context, 8192)
        XCTAssertEqual(reply, "image received")
        XCTAssertEqual(fallback.turnHistory.last?.first?.images, images)
        await engine.unload()
        XCTAssertTrue(fallback.unloaded)
        let loaded = await engine.loadedModelID
        let unloadedVision = await engine.supportsImageInput
        XCTAssertNil(loaded)
        XCTAssertFalse(unloadedVision)
    }

    func testFailedOptionalServerReleasesChildAndFallsBack() async throws {
        let root = try directory()
        _ = try executable(in: root)
        let fallback = FakeLLMEngine()
        let runtime = ManagedInferenceRuntime(kind: .omlx, revision: "test", executable: "server", models: ["example"], visionModels: [])
        let engine = ManagedMLXEngine(fallback: fallback, runtimeRoot: root, resolveRuntime: { _, _ in runtime })
        try await engine.load(directory: root, modelID: "example", diskBytes: 1)
        XCTAssertEqual(fallback.loadCount, 1)
        let externalMemory = await engine.externalResidentMemoryBytes
        let runtimeName = await engine.stats.runtimeName
        XCTAssertNil(externalMemory)
        XCTAssertNil(runtimeName)
        await engine.unload()
    }

    func testBonsaiNeverFallsIntoIncompatibleMLXLibrary() async throws {
        let root = try directory()
        let fallback = FakeLLMEngine()
        let engine = ManagedMLXEngine(fallback: fallback, runtimeRoot: root, resolveRuntime: { _, _ in nil })
        do {
            try await engine.load(directory: root, modelID: ManagedMLXEngine.bonsaiModelID, diskBytes: 1)
            XCTFail("A ternary checkpoint requires its native runtime")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("MLXFast"))
        }
        XCTAssertEqual(fallback.loadCount, 0)
    }
}

/// Explicit live gates exercise the same managed process lifecycle as the app.
final class LiveManagedInferenceTests: XCTestCase {
    func testOMLXChatVisionAndUnload() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_MANAGED_INFERENCE"] == "omlx" else {
            throw XCTSkip("Managed oMLX smoke is opt-in")
        }
        let runtime = try XCTUnwrap(ManagedInferenceRuntime.installed().first { $0.kind == .omlx })
        let engine = ManagedMLXEngine(fallback: FakeLLMEngine(), resolveRuntime: { _, _ in runtime })
        let qwen = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".cache/huggingface/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/73e3e38d981303bc594367cd910ea6eb48349da8")
        try await engine.load(directory: qwen, modelID: "qwen3-0.6b-omlx", diskBytes: 400_000_000)
        var answer = ""
        for try await chunk in engine.stream(adding: [.init(role: .user, content: "Reply with exactly ORCHID")], maxTokens: 64, temperature: 0) {
            answer += chunk
        }
        XCTAssertTrue(answer.contains("ORCHID"), answer)
        let stats = await engine.stats
        XCTAssertEqual(stats.runtimeName, "oMLX")
        XCTAssertGreaterThan(stats.generatedTokens, 0)
        await engine.unload()
        let unloaded = await engine.loadedModelID
        XCTAssertNil(unloaded)

        let smol = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/BeetCode/Models/smolvlm2-500m-mlx")
        try await engine.load(directory: smol, modelID: "smolvlm2-500m-mlx", diskBytes: 1_019_924_387)
        let imagePath = try XCTUnwrap(ProcessInfo.processInfo.environment["BEETCODE_LIVE_VISION_IMAGE"])
        let image = try XCTUnwrap(ChatImage.fromFile(at: URL(fileURLWithPath: imagePath)))
        let vision = await engine.supportsImageInput
        XCTAssertTrue(vision)
        var caption = ""
        for try await chunk in engine.stream(adding: [.init(role: .user, content: "Read the large words in this image. Return only those words.", images: [image])], maxTokens: 40, temperature: 0) {
            caption += chunk
        }
        XCTAssertTrue(caption.uppercased().contains("BONSAI"), caption)
        XCTAssertTrue(caption.contains("42"), caption)
        await engine.unload()
        let footprint = await engine.externalResidentMemoryBytes
        XCTAssertNil(footprint)
    }

    func testUpdatedMetalHuihuiVisionAndUnload() async throws {
        guard ProcessInfo.processInfo.environment["BEETCODE_LIVE_MANAGED_INFERENCE"] == "metal" else {
            throw XCTSkip("Managed Metal smoke is opt-in")
        }
        let runtime = try XCTUnwrap(ManagedInferenceRuntime.installed().first { $0.kind == .llamaMetal })
        let modelID = "Huihui-Qwen3.8-27B-abliterated-Q2_K"
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/BeetCode/Models/\(modelID)")
        let engine = GGUFEngine(preferredRuntime: runtime)
        try await engine.load(directory: directory, modelID: modelID, diskBytes: 10_864_592_160, contextSize: 4096)
        let imagePath = try XCTUnwrap(ProcessInfo.processInfo.environment["BEETCODE_LIVE_VISION_IMAGE"])
        let image = try XCTUnwrap(ChatImage.fromFile(at: URL(fileURLWithPath: imagePath)))
        var answer = ""
        for try await chunk in engine.stream(adding: [.init(role: .user, content: "Read the large words in this image. Return only those words.", images: [image])], maxTokens: 40, temperature: 0) {
            answer += chunk
        }
        XCTAssertTrue(answer.contains("BONSAI"), answer)
        XCTAssertTrue(answer.contains("42"), answer)
        let stats = await engine.stats
        XCTAssertEqual(stats.runtimeName, "llama.cpp Metal")
        await engine.unload()
        let loaded = await engine.loadedModelID
        let footprint = await engine.externalResidentMemoryBytes
        XCTAssertNil(loaded)
        XCTAssertNil(footprint)
    }
}
