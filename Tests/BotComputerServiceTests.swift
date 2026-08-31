import XCTest
@testable import BeetCode

final class BotComputerServiceTests: XCTestCase {
    func testPrepareCreatesPrivateSeparateWorkspaceAndBrowserProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)

        let first = try await service.prepare(profileID: "builder", name: "Builder")
        let second = try await service.prepare(profileID: "reviewer", name: "Reviewer")
        let records = try await service.load()

        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(first.workspacePath, second.workspacePath)
        XCTAssertNotEqual(first.browserProfilePath, second.browserProfilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.workspacePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.browserProfilePath))
        XCTAssertEqual(first.state, .prepared)
        XCTAssertTrue(first.containerName?.hasPrefix("beet-builder-") == true)

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testPreparedCatalogRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)
        let prepared = try await service.prepare(
            profileID: "research bot",
            name: "Researcher",
            backend: .isolatedWorkspace)

        let loaded = try await service.load()
        let restored = try XCTUnwrap(loaded.first)
        XCTAssertEqual(restored.id, prepared.id)
        XCTAssertEqual(restored.backend, .isolatedWorkspace)
        XCTAssertNil(restored.containerName)
    }

    func testIsolatedWorkspaceStartMarksRunningWithoutAContainer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)
        let prepared = try await service.prepare(
            profileID: "builder",
            name: "Builder",
            backend: .isolatedWorkspace)
        XCTAssertEqual(prepared.state, .prepared)
        let started = try await service.start(id: prepared.id)
        XCTAssertEqual(started.state, .running)
        XCTAssertEqual(started.workspacePath, prepared.workspacePath)
    }

    func testPrepareIfNeededDoesNotDuplicateAProfile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)
        let first = try await service.prepareSpecialist(profileID: "builder")
        let second = try await service.prepareSpecialist(profileID: "builder")
        XCTAssertEqual(first.id, second.id)
        let loaded = try await service.load()
        XCTAssertEqual(loaded.filter { $0.profileID == "builder" }.count, 1)
        do {
            _ = try await service.prepareSpecialist(profileID: "beet")
            XCTFail("generic beet computers are no longer created")
        } catch BotComputerError.unknownProfile {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testPrepareSpecialistsCreatesEachBotOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotComputerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)
        let first = try await service.prepareSpecialists()
        let second = try await service.prepareSpecialists()
        XCTAssertEqual(Set(first.map(\.profileID)), Set(["builder", "reviewer", "navigator", "researcher"]))
        XCTAssertEqual(Set(second.map(\.id)), Set(first.map(\.id)))
    }

    func testContainerCommandRewritesHostWorkspacePaths() {
        XCTAssertEqual(
            BotComputerService.execArguments(containerName: "beet-builder-abc", command: "ls"),
            ["exec", "-w", "/workspace", "beet-builder-abc", "sh", "-lc", "ls"])
        XCTAssertEqual(
            BotComputerService.rewriteCommandForContainer(
                "cat /tmp/bot/workspace/README.md",
                hostWorkspacePath: "/tmp/bot/workspace"),
            "cat /workspace/README.md")
        XCTAssertTrue(BotComputerService.guestPackages.contains("git"))
        XCTAssertTrue(BotComputerService.guestPackages.contains("python3"))
        XCTAssertTrue(BotComputerService.guestPackages.contains("nodejs"))
        XCTAssertTrue(BotComputerService.guestPackages.contains("bash"))
        XCTAssertTrue(BotComputerService.provisionCommand.hasPrefix("apk add --no-cache "))
        XCTAssertTrue(BotComputerService.guestReadyProbe.contains("command -v git"))
    }

    func testBotRunStorePersistsAndRecoversActiveRunsAsRecoverable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotRunTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotRunStore(root: root)
        var run = BotRunRecord.queued(
            profileID: "builder", profileName: "Builder",
            modelID: "chatgpt|gpt-5", prompt: "Build the feature")
        run.state = .running
        run.phase = "Implementing"
        try await store.save([run])

        let restored = await store.loadAll(recoverInterrupted: true)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, run.id)
        XCTAssertEqual(restored[0].modelID, run.modelID)
        XCTAssertEqual(restored[0].state, .recoverable)
        XCTAssertEqual(restored[0].phase, "Recoverable after restart")
    }

    func testBotRunStorePersistsOrderedEventsAndAcknowledgedCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotRunHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotRunStore(root: root)
        let runID = UUID()

        _ = try await store.appendEvent(
            runID: runID, kind: .created, phase: "Queued", detail: "objective")
        _ = try await store.appendEvent(
            runID: runID, kind: .started, phase: "Starting")
        let command = try await store.enqueueCommand(
            runID: runID, kind: .steer, payload: "Focus on tests")
        try await store.acknowledgeCommand(
            command.id, accepted: true, result: "Steering delivered.")

        let events = await store.loadEvents(runID: runID)
        let commands = await store.loadCommands(runID: runID)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertEqual(events.map(\.kind), [.created, .started])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].payload, "Focus on tests")
        XCTAssertEqual(commands[0].state, .acknowledged)
        XCTAssertNotNil(commands[0].acknowledgedAt)
    }

    func testAdaptivePlannerBuildsParallelDiscoveryThenBuildAndReview() {
        let plan = BotAdaptivePlanner.plan(
            prompt: "Research the latest browser flow and implement the feature in the app")
        XCTAssertEqual(
            plan.nodes.map(\.specialistID),
            ["researcher", "navigator", "builder", "reviewer"])
        XCTAssertEqual(plan.nodes[2].dependencyKeys, ["research", "navigate"])
        XCTAssertEqual(plan.nodes[3].dependencyKeys, ["build"])
        XCTAssertEqual(plan.nodes[0].phase, .research)
        XCTAssertEqual(plan.nodes[0].requiredEvidence, [.sources])
        XCTAssertEqual(plan.nodes[2].requiredEvidence, [.execution, .verification])
        XCTAssertFalse(plan.nodes[2].acceptanceCriteria.isEmpty)
        XCTAssertTrue(plan.nodes[2].prompt.contains("Completion criteria:"))
    }

    func testBotEvidenceSeparatesReportedCompletionFromVerification() {
        let evidence = BotRunEvidence(
            phase: .code,
            confidence: .reportedDone,
            required: [.execution, .verification],
            observed: [.execution])

        XCTAssertEqual(evidence.label, "Code · reported done")
        XCTAssertEqual(evidence.missing, [.verification])
    }

    @MainActor
    func testCoordinatorStartsIndependentRemoteRunsConcurrently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotCoordinatorRemoteTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        var started: [UUID] = []
        coordinator.startHandler = { run in
            started.append(run.id)
            return .accepted(UUID())
        }

        let first = try coordinator.start(
            profileID: "builder", profileName: "Builder",
            modelID: "openai|gpt-5", prompt: "Build").get()
        let second = try coordinator.start(
            profileID: "researcher", profileName: "Researcher",
            modelID: "chatgpt|gpt-5", prompt: "Research").get()
        await settle()

        XCTAssertEqual(Set(started), Set([first, second]))
        XCTAssertEqual(coordinator.runs.first(where: { $0.id == first })?.state, .running)
        XCTAssertEqual(coordinator.runs.first(where: { $0.id == second })?.state, .running)
    }

    @MainActor
    func testCoordinatorSerializesLocalInferenceAndExposesQueue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotCoordinatorLocalTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        var started: [UUID] = []
        coordinator.startHandler = { run in
            started.append(run.id)
            return .accepted(UUID())
        }

        let first = try coordinator.start(
            profileID: "builder", profileName: "Builder",
            modelID: "local|model-a", prompt: "Build").get()
        let second = try coordinator.start(
            profileID: "reviewer", profileName: "Reviewer",
            modelID: "local|model-a", prompt: "Review").get()
        await settle()

        XCTAssertEqual(started, [first])
        XCTAssertEqual(coordinator.runs.first(where: { $0.id == second })?.state, .queued)
        XCTAssertEqual(coordinator.runs.first(where: { $0.id == second })?.queuePosition, 1)

        coordinator.sync(
            runID: first, phase: .finished, finish: .completed("Done"), output: "Done")
        await settle()
        XCTAssertEqual(started, [first, second])
    }

    /// The console's file browser takes a path from the paired client, so escaping the
    /// workspace is the thing that must not be possible.
    func testWorkspaceBrowsingIsConfinedToTheWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotConsoleTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = BotComputerService(root: root)
        let bot = try await service.prepare(
            profileID: "builder", name: "Builder", backend: .isolatedWorkspace)
        let workspace = URL(fileURLWithPath: bot.workspacePath, isDirectory: true)

        try "inside".write(
            to: workspace.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("src"), withIntermediateDirectories: true)
        // A secret next to the workspace, and a symlink inside it pointing at that secret.
        let outside = root.appendingPathComponent("outside.txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("escape"), withDestinationURL: outside)

        let listing = try await service.listWorkspace(id: bot.id)
        XCTAssertEqual(listing.first?.name, "src", "directories sort first")
        XCTAssertTrue(listing.contains { $0.name == "notes.txt" })
        XCTAssertTrue(
            listing.allSatisfy { !$0.path.hasPrefix("/") },
            "paths must stay relative so the host layout never crosses the wire")

        let contents = try await service.readWorkspaceFile(id: bot.id, relativePath: "notes.txt")
        XCTAssertEqual(contents, "inside")

        for escape in ["../outside.txt", "src/../../outside.txt", "/etc/hosts", "escape"] {
            do {
                _ = try await service.readWorkspaceFile(id: bot.id, relativePath: escape)
                XCTFail("\(escape) must not resolve outside the workspace")
            } catch {
                // expected
            }
        }
    }

    /// Four specialists sharing one Mac. The old fixed 4 CPU / 4 GB asked for 16 GB and 16
    /// cores no matter what the host had.
    func testContainerResourcesLeaveHeadroomForFourBots() {
        let sixteenGigEightCore = ProcessInfoStub(cores: 8, bytes: 16 * 1_073_741_824)
        let small = BotComputerService.containerResources(processInfo: sixteenGigEightCore)
        XCTAssertEqual(small.cpus, "2")
        XCTAssertEqual(small.memory, "2G")

        // Even a very large Mac stays inside the per-bot ceiling.
        let huge = BotComputerService.containerResources(
            processInfo: ProcessInfoStub(cores: 128, bytes: 512 * 1_073_741_824))
        XCTAssertEqual(huge.cpus, "8")
        XCTAssertEqual(huge.memory, "8G")

        // And a small machine still gets a usable floor rather than zero.
        let tiny = BotComputerService.containerResources(
            processInfo: ProcessInfoStub(cores: 2, bytes: 4 * 1_073_741_824))
        XCTAssertEqual(tiny.cpus, "2")
        XCTAssertEqual(tiny.memory, "2G")
    }

    func testGuestImageIsPinned() {
        XCTAssertFalse(
            BotComputerService.guestImage.hasSuffix(":latest"),
            "a moving base image breaks apk provisioning inside a container nobody is watching")
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}

/// Stands in for the host so container sizing can be checked on any machine.
private final class ProcessInfoStub: ProcessInfo, @unchecked Sendable {
    private let cores: Int
    private let bytes: UInt64

    init(cores: Int, bytes: UInt64) {
        self.cores = cores
        self.bytes = bytes
        super.init()
    }

    override var activeProcessorCount: Int { cores }
    override var physicalMemory: UInt64 { bytes }
}
