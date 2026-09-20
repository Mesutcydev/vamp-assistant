import XCTest
@testable import BeetCode

/// Vision sidecar (SmolVLM2) integration: catalog shape, tolerant decoding,
/// and provider routing. Hermetic — the local describe seam is stubbed, no
/// MLX, no network, no Keychain.
final class VisionTests: XCTestCase {

    // MARK: Catalog

    func testBundledVisionEntriesAreWellFormed() {
        let vision = ModelCatalog.bundled.filter { $0.role == .vision }
        XCTAssertEqual(vision.count, 2, "SmolVLM2 500M + 2.2B sidecars are curated")
        for model in vision {
            XCTAssertEqual(model.family, "SmolVLM2")
            XCTAssertEqual(model.format, .mlx, "\(model.id): sidecars run in-process via MLXVLM")
            XCTAssertTrue(model.repo.contains("SmolVLM2"), "\(model.id): repo should point at a SmolVLM2 build")
            XCTAssertGreaterThan(model.diskBytes, 0)
        }
    }

    func testChatIsTheDefaultRole() {
        let chat = ModelCatalog.bundled.filter { $0.role == .chat }
        XCTAssertEqual(chat.count, ModelCatalog.bundled.count - 2)
    }

    // MARK: Tolerant decoding

    func testCatalogDecodesWithoutFormatAndRoleKeys() throws {
        // Shape written by builds predating the format/role fields.
        let json = """
            [{"id":"old","repo":"a/b","displayName":"Old","family":"Qwen3",
              "parameters":"1B","quantization":"4-bit","diskBytes":1000,
              "contextWindow":32768,"minRAMGB":6,"recommendedRAMGB":8,
              "notes":"legacy"}]
            """
        let models = try JSONDecoder().decode([CatalogModel].self, from: Data(json.utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].format, .mlx)
        XCTAssertEqual(models[0].role, .chat)
    }

    func testVisionRoleRoundTrips() throws {
        let model = CatalogModel(
            id: "v", repo: "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
            displayName: "V", family: "SmolVLM2", parameters: "500M",
            quantization: "bf16", diskBytes: 1, contextWindow: 16_384,
            minRAMGB: 4, recommendedRAMGB: 6, notes: "", role: .vision)
        let data = try JSONEncoder().encode([model])
        let decoded = try JSONDecoder().decode([CatalogModel].self, from: data)
        XCTAssertEqual(decoded.first?.role, .vision)
    }

    // MARK: Picker

    func testPickerPrefersLargerInstalledSidecar() {
        let catalog = ModelCatalog.bundled
        // Only the 500M installed → picked.
        XCTAssertEqual(
            VisionProvider.pickVisionModel(from: catalog, isInstalled: { $0 == "smolvlm2-500m-mlx" })?.id,
            "smolvlm2-500m-mlx")
        // Both installed → the 2.2B wins (quality).
        XCTAssertEqual(
            VisionProvider.pickVisionModel(from: catalog, isInstalled: { _ in true })?.id,
            "smolvlm2-2.2b-mlx")
        // None installed → nil.
        XCTAssertNil(VisionProvider.pickVisionModel(from: catalog, isInstalled: { _ in false }))
        // Chat models are never picked, even when installed.
        XCTAssertNil(VisionProvider.pickVisionModel(from: catalog, isInstalled: { $0 == "qwen3-4b-4bit" }))
    }

    // MARK: Routing

    func testDescribePrefersLocalSidecar() async throws {
        let resolution = VisionProvider.LocalResolution(
            model: ModelCatalog.bundled.first { $0.role == .vision }!,
            directory: URL(fileURLWithPath: "/tmp/unused"),
            diskBytes: 1)
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = { resolution }
        VisionProvider.localDescribe = { _, _, _ in "local description" }

        let result = try await VisionProvider.describe(
            imageAt: URL(fileURLWithPath: "/tmp/unused.png"), prompt: "p")
        XCTAssertEqual(result, "local description")
    }

    func testLocalOnlyDescribeUsesSmolVLMSeamAndNeverNeedsBYOK() async throws {
        let resolution = VisionProvider.LocalResolution(
            model: ModelCatalog.bundled.first { $0.role == .vision }!,
            directory: URL(fileURLWithPath: "/tmp/unused"),
            diskBytes: 1)
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = { resolution }
        VisionProvider.localDescribe = { _, url, prompt in
            "local:\(url.lastPathComponent):\(prompt)"
        }

        let result = try await VisionProvider.describeLocallyIfAvailable(
            imageAt: URL(fileURLWithPath: "/tmp/screen.png"), prompt: "inspect UI")
        XCTAssertEqual(result, "local:screen.png:inspect UI")

        VisionProvider.localResolver = { nil }
        let unavailableResult = try await VisionProvider.describeLocallyIfAvailable(
            imageAt: URL(fileURLWithPath: "/tmp/screen.png"), prompt: "inspect UI")
        XCTAssertNil(unavailableResult)
    }

    func testLocalFailureFallsThroughToBYOK() async throws {
        struct Probe: Error {}
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = {
            VisionProvider.LocalResolution(
                model: ModelCatalog.bundled.first { $0.role == .vision }!,
                directory: URL(fileURLWithPath: "/tmp/unused"),
                diskBytes: 1)
        }
        VisionProvider.localDescribe = { _, _, _ in throw Probe() }

        // No BYOK keys in the test host → the failure surfaces as
        // noProvider, proving the local error didn't escape directly.
        do {
            _ = try await VisionProvider.describe(
                imageAt: URL(fileURLWithPath: "/tmp/unused.png"), prompt: "p")
            // A host WITH a vision BYOK key would take the network path
            // instead — acceptable: the fall-through is what we assert.
        } catch let error as VisionProvider.VisionError {
            guard case .noProvider = error else {
                return XCTFail("expected noProvider, got \(error)")
            }
        }
    }

    func testNoProviderErrorMentionsSmolVLM2() {
        let message = VisionProvider.VisionError.noProvider.errorDescription ?? ""
        XCTAssertTrue(message.contains("SmolVLM2"))
        XCTAssertTrue(message.contains("Model Manager"))
    }

    // MARK: Live smoke (opt-in)

    /// Real end-to-end proof: loads the actual SmolVLM2 weights through
    /// VisionEngine and describes an image. Opt-in (touch
    /// /tmp/beetcode-vlm-smoke — xcodebuild doesn't reliably forward env
    /// vars to the test host) because it needs a downloaded model and
    /// touches MLX — the regular suite stays hermetic.
    func testLiveSmolVLM2Describe() async throws {
        let flag = "/tmp/beetcode-vlm-smoke"
        guard FileManager.default.fileExists(atPath: flag) else { return }
        let model = ModelCatalog.bundled.first { $0.id == "smolvlm2-500m-mlx" }!
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeetCode/Models/smolvlm2-500m-mlx", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path) else {
            XCTFail("SmolVLM2-500M not downloaded to \(dir.path)")
            return
        }
        let image = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["BEETCODE_VLM_IMAGE"]
                ?? "/Users/m/Downloads/new project/menu-screenshot.png")
        let result = try await VisionEngine.shared.describe(
            imageAt: image,
            prompt: "Describe this image concisely for a coding agent.",
            model: model,
            directory: dir,
            diskBytes: model.diskBytes)
        print("SMOLVLM2_SAYS: \(result)")
        XCTAssertFalse(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}


// MARK: - Vision inside a real agent session

/// describe_image executing inside an AgentLoop run: the loop resolves the
/// call through the (stubbed) provider and the answer flows back as a tool
/// observation. Same harness as AgentLoopTests — FakeLLMEngine, temp
/// workspace, no MLX, no network, no Keychain.
final class VisionSessionTests: XCTestCase {

    private var workspace: TempWorkspace!
    private var engine: FakeLLMEngine!
    /// Three backticks (built without literal backticks in source).
    private let fence = "\u{60}\u{60}\u{60}"

    override func setUpWithError() throws {
        workspace = TempWorkspace()
        engine = FakeLLMEngine()
        TaskCapsuleStore.shared.overrideDirectory = workspace.url(for: "Capsules")
    }

    override func tearDownWithError() throws {
        TaskCapsuleStore.shared.overrideDirectory = nil
        workspace = nil
        engine = nil
    }

    private func toolCall(_ name: String, _ arguments: String) -> String {
        "\(fence)tool\n{\"name\": \"\(name)\", \"arguments\": \(arguments)}\n\(fence)"
    }

    private func makeVisionLoop() -> AgentLoop {
        let permissions = PermissionGate(
            autoApproveEdits: false,
            autoApproveCommands: false,
            workspace: workspace.workspace)
        return AgentLoop(
            engine: engine,
            workspace: workspace.workspace,
            tools: [ReadFileTool(), DescribeImageTool()],
            permissions: permissions,
            configuration: AgentLoop.Configuration())
    }

    private func toolResults(_ collector: EventCollector) -> [(name: String, output: String, failed: Bool)] {
        collector.events { event in
            if case .toolCallFinished(let invocation, let output, let failed) = event {
                return (invocation.name, output, failed)
            }
            return nil
        }
    }

    func testDescribeImageExecutesInsideAgentSession() async throws {
        workspace.write("fake-png-bytes", to: "menu.png")
        let resolution = VisionProvider.LocalResolution(
            model: ModelCatalog.bundled.first { $0.role == .vision }!,
            directory: URL(fileURLWithPath: "/tmp/unused"),
            diskBytes: 1)
        let originalResolver = VisionProvider.localResolver
        let originalDescribe = VisionProvider.localDescribe
        defer {
            VisionProvider.localResolver = originalResolver
            VisionProvider.localDescribe = originalDescribe
        }
        VisionProvider.localResolver = { resolution }
        VisionProvider.localDescribe = { _, _, _ in "a menu bar with three icons" }

        engine.enqueue(texts: [
            "Checking the screenshot.\n"
                + toolCall("describe_image", #"{"path": "menu.png", "prompt": "what is on screen"}"#),
            "The screenshot shows a menu bar with three icons. Task complete.",
        ])
        let loop = makeVisionLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "what does the menu show?")
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: 10)
        _ = await collection

        XCTAssertNotNil(finish, "loop never finished")
        XCTAssertEqual(collector.toolCalls().map(\.name), ["describe_image"])
        XCTAssertTrue(collector.approvals().isEmpty, "image describes are reads — never gated")
        let results = toolResults(collector)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.output, "a menu bar with three icons")
        XCTAssertEqual(results.first?.failed, false)
        XCTAssertEqual(
            collector.finish,
            .completed("The screenshot shows a menu bar with three icons. Task complete."))
    }

    /// A refused path must come back as a FAILED observation the model can
    /// react to — never a hang or a silent success. Deterministic: the
    /// workspace guard throws before any provider (or network) is touched.
    func testDescribeImageRefusalSurfacesAsFailedObservation() async throws {
        workspace.write("fake-png-bytes", to: "menu.png")
        engine.enqueue(texts: [
            toolCall("describe_image", #"{"path": "../outside.png"}"#),
            "The path was refused, so I cannot inspect that file. Task complete.",
        ])
        let loop = makeVisionLoop()
        let collector = EventCollector()
        let stream = await loop.run(userMessage: "describe ../outside.png")
        async let collection: Void = collector.start(stream)
        let finish = await collector.waitForFinish(timeout: 10)
        _ = await collection

        XCTAssertNotNil(finish, "loop never finished")
        let results = toolResults(collector)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.failed, true)
        XCTAssertFalse(results.first?.output.isEmpty ?? true,
                       "the failure reason must reach the model")
    }
}

/// Native image input to a local GGUF model (llama.cpp multimodal projector):
/// projector discovery, launch flags, OpenAI content parts, containers, and
/// session persistence. Hermetic — no llama-server, no weights, no network.
final class GGUFVisionInputTests: XCTestCase {

    // MARK: Projector vs weights

    func testSelectGGUFIgnoresProjectorFiles() {
        let files = [
            "Ternary-Bonsai-2-27B-PQ2_0.gguf",
            "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
            "README.md",
        ]
        XCTAssertEqual(
            GGUFEngine.Planner.selectGGUF(named: files),
            "Ternary-Bonsai-2-27B-PQ2_0.gguf",
            "the projector's longer name must not win the longest-name rule")
    }

    func testProjectorFilePrefersTheQ8PackForTheSameModel() {
        let files = [
            "Ternary-Bonsai-2-27B-PQ2_0.gguf",
            "Ternary-Bonsai-2-27B-mmproj-BF16.gguf",
            "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
        ]
        XCTAssertEqual(
            GGUFEngine.Planner.projectorFile(
                named: files, modelID: "Ternary-Bonsai-2-27B-PQ2_0"),
            "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf")
        XCTAssertNil(
            GGUFEngine.Planner.projectorFile(named: ["model.gguf"]),
            "a folder without a projector must stay text-only")
    }

    func testServerArgumentsCarryMmprojOnlyWhenPresent() throws {
        let withProjector = GGUFEngine.Planner.serverArguments(
            modelPath: "/m/model.gguf", port: 8901,
            mmprojPath: "/m/model-mmproj.gguf")
        let flagIndex = try XCTUnwrap(withProjector.firstIndex(of: "--mmproj"))
        XCTAssertEqual(withProjector[flagIndex + 1], "/m/model-mmproj.gguf")

        let textOnly = GGUFEngine.Planner.serverArguments(modelPath: "/m/model.gguf", port: 8901)
        XCTAssertFalse(
            textOnly.contains("--mmproj"),
            "a text-only launch must never load a vision tower")
    }

    // MARK: OpenAI content parts

    func testImageTurnSerializesAsContentParts() throws {
        let image = ChatImage(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            mimeType: "image/png",
            name: "screen.png")
        let messages = RemoteLLMClient.prepareOpenAIMessages([
            ChatTurn(role: .user, content: "what is on this screen?", images: [image]),
        ])
        let encoded = try JSONEncoder().encode(messages)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let content = try XCTUnwrap(json.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.last?["type"] as? String, "image_url")
        let url = try XCTUnwrap(
            (content.last?["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"))

        // Round-trip: the local API server decodes what a client posted.
        let decoded = try JSONDecoder().decode(
            [RemoteLLMClient.OpenAIMessage].self, from: encoded)
        XCTAssertEqual(decoded.first?.content, "what is on this screen?")
        XCTAssertEqual(decoded.first?.images.first?.data, image.data)
    }

    func testTextOnlyTurnStillEncodesStringContent() throws {
        let messages = RemoteLLMClient.prepareOpenAIMessages([
            ChatTurn(role: .user, content: "hi"),
        ])
        let encoded = try JSONEncoder().encode(messages)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        XCTAssertEqual(
            json.first?["content"] as? String, "hi",
            "providers that never see an image must get the unchanged payload")
    }

    // MARK: Containers

    func testOnlyContainersLlamaCppDecodesAreSentNatively() {
        XCTAssertTrue(ChatImage.canSendNatively(pathExtension: "PNG"))
        XCTAssertTrue(ChatImage.canSendNatively(pathExtension: "jpeg"))
        XCTAssertFalse(
            ChatImage.canSendNatively(pathExtension: "heic"),
            "HEIC must keep the CoreImage sidecar path, not reach the projector")
        XCTAssertFalse(ChatImage.canSendNatively(pathExtension: "svg"))
    }

    func testMimeTypeIsSniffedFromMagicBytesNotTheExtension() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        XCTAssertEqual(ChatImage.sniffMimeType(png, pathExtension: "dat"), "image/png")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        XCTAssertEqual(ChatImage.sniffMimeType(jpeg, pathExtension: ""), "image/jpeg")
    }

    // MARK: Capability default

    func testEnginesOptOutOfImageInputByDefault() async {
        let engine = FakeLLMEngine()
        let capable = await engine.supportsImageInput
        XCTAssertFalse(
            capable,
            "only a GGUF server launched with a projector may claim image input")
    }

    // MARK: Persistence

    func testSessionMessageRoundTripsImages() throws {
        let image = ChatImage(data: Data([1, 2, 3, 4]), mimeType: "image/png", name: "a.png")
        let message = SessionMessage(
            role: .user, content: "look", toolName: nil, timestamp: Date(),
            images: [SessionImage(image)])
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(SessionMessage.self, from: data)
        XCTAssertEqual(decoded.images?.first?.chatImage?.data, image.data)
        XCTAssertEqual(decoded.images?.first?.mimeType, "image/png")
        XCTAssertEqual(decoded.content, "look")
    }

    func testLegacySessionMessageWithoutImagesStillDecodes() throws {
        let legacy = #"{"role":"user","content":"old","timestamp":0}"#
        let decoded = try JSONDecoder().decode(
            SessionMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.images)
        XCTAssertEqual(decoded.content, "old")
    }
}

/// LoRA adapters staged beside GGUF weights (runtime A/B of an ablation
/// adapter): never served as the base model, applied only when switched on.
final class GGUFLoraAdapterTests: XCTestCase {

    func testAdapterIsNeverMistakenForWeights() throws {
        let files = [
            "Ternary-Bonsai-2-27B-PQ2_0.gguf",
            "Ternary-Bonsai-2-27B-abliterate-lora.gguf",
            "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
        ]
        XCTAssertEqual(
            GGUFEngine.Planner.selectGGUF(named: files),
            "Ternary-Bonsai-2-27B-PQ2_0.gguf")
        XCTAssertEqual(
            GGUFEngine.Planner.loraFile(
                named: files, modelID: "Ternary-Bonsai-2-27B-PQ2_0"),
            "Ternary-Bonsai-2-27B-abliterate-lora.gguf")
        XCTAssertNil(GGUFEngine.Planner.loraFile(named: ["model.gguf"]))
        XCTAssertTrue(GGUFEngine.Planner.isLoraFile("model-abliterate.gguf"))
        XCTAssertFalse(GGUFEngine.Planner.isLoraFile("model-mmproj-Q8_0.gguf"))
    }

    func testLoraScaledIsOnlyPassedWhenSwitchedOn() throws {
        let applied = GGUFEngine.Planner.serverArguments(
            modelPath: "/m/w.gguf", port: 8901,
            loraPath: "/m/ablate-lora.gguf", loraScale: 2)
        let flag = try XCTUnwrap(applied.firstIndex(of: "--lora-scaled"))
        XCTAssertEqual(applied[flag + 1], "/m/ablate-lora.gguf:2")

        let off = GGUFEngine.Planner.serverArguments(
            modelPath: "/m/w.gguf", port: 8901,
            loraPath: "/m/ablate-lora.gguf", loraScale: 0)
        XCTAssertFalse(
            off.contains("--lora-scaled"),
            "scale 0 is the A/B switch: the adapter stays on disk, unloaded")

        let absent = GGUFEngine.Planner.serverArguments(modelPath: "/m/w.gguf", port: 8901)
        XCTAssertFalse(absent.contains("--lora-scaled"))
        XCTAssertEqual(GGUFEngine.Planner.loraScaleArgument(1.0), "1")
        XCTAssertEqual(GGUFEngine.Planner.loraScaleArgument(0.5), "0.5")
    }
}
