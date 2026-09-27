import XCTest
@testable import BeetCode

final class BotComputerServiceTests: XCTestCase {
    @MainActor
    func testDraftsSurviveStoreRecreationAndStayPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drafts.json")
        let drafts = BotDraftStore(url: url)
        drafts.set("Keep this task", for: "builder:task")
        drafts.set("Research draft", for: "researcher:task")
        let restored = BotDraftStore(url: url)
        XCTAssertEqual(restored.value(for: "builder:task"), "Keep this task")
        XCTAssertEqual(restored.value(for: "researcher:task"), "Research draft")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber, 0o600)
    }

    @MainActor
    func testFailedPersistencePreventsRuntimeStartAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("blocked".utf8).write(to: root)
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        var starts = 0
        coordinator.startHandler = { _ in starts += 1; return .accepted(UUID()) }
        _ = try coordinator.start(profileID: "builder", profileName: "Builder", modelID: "api|test", prompt: "Task").get()
        await settle()
        XCTAssertEqual(starts, 0)
        XCTAssertNotNil(coordinator.persistenceError)
        try FileManager.default.removeItem(at: root)
        await coordinator.retryPersistence()
        await settle()
        XCTAssertEqual(starts, 1)
        XCTAssertNil(coordinator.persistenceError)
    }

    @MainActor
    func testAnswerIsNotDeliveredWhenCommandStorageFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotRunStore(root: root)
        var run = BotRunRecord.queued(profileID: "builder", profileName: "Builder", modelID: "api|test", prompt: "Task")
        run.state = .needsInput
        run.sessionID = UUID()
        try await store.save([run])
        let coordinator = BotRunCoordinator(store: store)
        await settle()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bot-run-commands.json"), withIntermediateDirectories: true)
        var delivered = false
        coordinator.answerHandler = { _, _ in delivered = true; return true }
        let accepted = await coordinator.deliverCommand(runID: run.id, kind: .answer, payload: "Keep my answer")
        XCTAssertFalse(accepted)
        XCTAssertFalse(delivered)
        XCTAssertNotNil(coordinator.run(for: "builder")?.errorMessage)
    }

    @MainActor
    func testRejectedAnswerReturnsFalseAndRecordsRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotRunStore(root: root)
        var run = BotRunRecord.queued(profileID: "builder", profileName: "Builder", modelID: "api|test", prompt: "Task")
        run.state = .needsInput
        try await store.save([run])
        let coordinator = BotRunCoordinator(store: store)
        await settle()
        coordinator.answerHandler = { _, _ in false }
        let accepted = await coordinator.deliverCommand(runID: run.id, kind: .answer, payload: "Answer")
        XCTAssertFalse(accepted)
        XCTAssertNotNil(coordinator.run(for: "builder")?.errorMessage)
    }

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

    /// Bot prompts and model output are as sensitive as chat content; the
    /// state files must not be world-readable.
    func testBotRunStoreHardensFilePermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotRunPerms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotRunStore(root: root)
        var run = BotRunRecord.queued(
            profileID: "builder", profileName: "Builder",
            modelID: "chatgpt|gpt-5", prompt: "Private plan")
        run.latestOutput = "private output"
        try await store.save([run])

        let file = root.appendingPathComponent("bot-runs.json")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    /// A corrupt state file must be preserved for recovery, never replaced by
    /// the empty snapshot the next persist would otherwise write over it.
    func testCorruptBotRunFileIsQuarantinedNotOverwritten() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeetCodeBotRunCorrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = BotRunStore(root: root)
        let file = root.appendingPathComponent("bot-runs.json")
        try Data("{ this is not valid json".utf8).write(to: file)

        let loaded = await store.loadAll(recoverInterrupted: true)
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "the unreadable file should be moved aside")
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("bot-runs.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        let preserved = try String(
            contentsOf: root.appendingPathComponent(backups[0]), encoding: .utf8)
        XCTAssertTrue(preserved.contains("not valid json"))
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
            modelID: "local|model-a", prompt: "Research").get()
        await waitUntil { started.count == 1 }

        XCTAssertEqual(started, [first])
        XCTAssertEqual(coordinator.runs.first(where: { $0.id == second })?.state, .queued)
        XCTAssertEqual(coordinator.runs.first(where: { $0.id == second })?.queuePosition, 1)

        coordinator.sync(
            runID: first, phase: .finished, finish: .completed("Done"), output: "Done")
        await waitUntil { started.count == 2 }
        XCTAssertEqual(started, [first, second])
    }

    /// Polls instead of sleeping a fixed interval: run dispatch waits on the
    /// durable snapshot write, which can exceed any single sleep under load.
    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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

    func testAdaptivePlannerMatchesWholeWordsOnly() {
        func route(_ prompt: String) -> [String] {
            BotAdaptivePlanner.plan(prompt: prompt).nodes.map(\.specialistID)
        }
        // "form" inside information/platform used to summon the Navigator.
        XCTAssertEqual(route("Review the information architecture of the platform"), ["reviewer"])
        // "app" inside approved used to add a Builder and Reviewer to pure research.
        XCTAssertEqual(route("Research which tokens are currently approved"), ["researcher"])
        XCTAssertEqual(route("Fixing the login pages"), ["navigator", "builder", "reviewer"])
    }

    /// The controller clears its stream before publishing `finish`, so the final answer only
    /// arrives on `.completed`. Every completed run used to end with empty output.
    @MainActor
    func testCompletedRunKeepsFinalAnswerAndIgnoresLateEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        coordinator.startHandler = { _ in .accepted(UUID()) }
        let id = try coordinator.start(
            profileID: "builder", profileName: "Builder", modelID: "api|test", prompt: "Build").get()
        await waitUntil { coordinator.runs.first { $0.id == id }?.sessionID != nil }

        coordinator.sync(runID: id, phase: .finished, finish: .completed("Changed a.swift; tests pass."), output: "")
        coordinator.sync(runID: id, phase: .finished, finish: .cancelled, output: "")

        let run = try XCTUnwrap(coordinator.runs.first { $0.id == id })
        XCTAssertEqual(run.state, .completed)
        XCTAssertEqual(run.latestOutput, "Changed a.swift; tests pass.")
        XCTAssertEqual(run.artifacts?.map(\.value), ["Changed a.swift; tests pass."])
    }

    @MainActor
    func testRetryingBuilderDoesNotFailItsReviewer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        coordinator.startHandler = { _ in .accepted(UUID()) }
        _ = try coordinator.orchestrate(prompt: "Implement the feature", modelID: "api|test").get()
        func state(_ profile: String) -> BotRunState? {
            coordinator.runs.first { $0.profileID == profile }?.state
        }
        let builder = try XCTUnwrap(coordinator.runs.first { $0.profileID == "builder" }?.id)
        await waitUntil { coordinator.runs.first { $0.id == builder }?.sessionID != nil }

        coordinator.sync(runID: builder, phase: .finished, finish: .engineError("503"), output: "")

        XCTAssertEqual(state("builder"), .queued)
        XCTAssertEqual(state("reviewer"), .queued)
        await waitUntil { state("builder") == .running }
        XCTAssertEqual(state("builder"), .running)
        XCTAssertEqual(state("reviewer"), .queued)
    }

    @MainActor
    func testStopWhileStartingStaysStopped() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        var release: CheckedContinuation<Void, Never>?
        var runtimeExists = false
        var stops = 0
        coordinator.startHandler = { _ in
            await withCheckedContinuation { release = $0 }
            runtimeExists = true
            return .accepted(UUID())
        }
        // Mirrors AppState: nothing to stop until the runtime exists.
        coordinator.stopHandler = { _ in stops += 1; return runtimeExists }
        let id = try coordinator.start(
            profileID: "builder", profileName: "Builder", modelID: "local|m", prompt: "Build").get()
        await waitUntil { release != nil }

        XCTAssertTrue(coordinator.stop(runID: id))
        await waitUntil { coordinator.runs.first { $0.id == id }?.state == .stopped }
        release?.resume()
        await waitUntil { stops == 1 }

        XCTAssertEqual(stops, 1, "the runtime created after Stop must be cancelled")
        XCTAssertEqual(coordinator.runs.first { $0.id == id }?.state, .stopped)
    }

    func testEvidenceComesFromWhatToolsDid() {
        let edit = BotToolTrace(name: "apply_patch", command: nil, failed: false)
        let check = BotToolTrace(name: "run_command", command: "swift test", failed: false)
        XCTAssertEqual(BotRunEvidence.observed(from: [edit, check], phase: .code), [.execution, .verification])
        // An edit after the passing check means the final state was never checked.
        XCTAssertEqual(BotRunEvidence.observed(from: [check, edit], phase: .code), [.execution])
        XCTAssertEqual(BotRunEvidence.observed(
            from: [edit, BotToolTrace(name: "run_command", command: "swift test", failed: true)],
            phase: .code), [.execution])
        XCTAssertEqual(BotRunEvidence.observed(
            from: [BotToolTrace(name: "run_command", command: "ls tests", failed: false)],
            phase: .code), [.execution])
        XCTAssertEqual(BotRunEvidence.observed(
            from: [BotToolTrace(name: "web_fetch", command: nil, failed: false)],
            phase: .research), [.sources, .execution])
        XCTAssertEqual(BotRunEvidence.observed(from: [], phase: .review), [])
    }

    @MainActor
    func testWorkflowEvidenceCompletesFromReportsAndAPassingReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = BotRunCoordinator(store: BotRunStore(root: root))
        coordinator.startHandler = { _ in .accepted(UUID()) }
        _ = try coordinator.orchestrate(prompt: "Implement the feature", modelID: "api|test").get()
        func run(_ profile: String) -> BotRunRecord? { coordinator.runs.first { $0.profileID == profile } }
        let builder = try XCTUnwrap(run("builder")?.id)
        await waitUntil { run("builder")?.sessionID != nil }

        coordinator.sync(
            runID: builder, phase: .finished, finish: .completed("Done.\nAC1: met\nAC2: met"),
            output: "", trace: [BotToolTrace(name: "apply_patch", command: nil, failed: false)])
        XCTAssertEqual(run("builder")?.acceptanceCriteria?.map(\.satisfied), [true, true])
        XCTAssertEqual(run("builder")?.evidence?.confidence, .reportedDone)
        XCTAssertEqual(run("builder")?.evidence?.missing, [.verification])

        let reviewer = try XCTUnwrap(run("reviewer")?.id)
        await waitUntil { run("reviewer")?.sessionID != nil }
        XCTAssertTrue(run("reviewer")?.prompt.contains("- [x] The requested outcome is implemented") == true)
        coordinator.sync(
            runID: reviewer, phase: .finished,
            finish: .completed("No issues.\nAC1: met\nAC2: met\nVerdict: pass"),
            output: "", trace: [BotToolTrace(name: "read_file", command: nil, failed: false)])

        XCTAssertEqual(run("reviewer")?.evidence?.confidence, .verified)
        XCTAssertEqual(run("builder")?.evidence?.confidence, .verified)
    }

    @MainActor
    func testHistoryKeepsLiveRunsTheirDependenciesAndTheNewestFinished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotRunStore(root: root)
        let now = Date()
        let finished = (0..<(BotRunCoordinator.retainedFinishedRuns + 2)).map { index in
            var run = BotRunRecord.queued(profileID: "researcher", profileName: "Researcher", modelID: "api|test", prompt: "R")
            run.state = .completed
            run.updatedAt = now.addingTimeInterval(Double(index))
            return run
        }
        var live = BotRunRecord.queued(profileID: "builder", profileName: "Builder", modelID: "api|test", prompt: "B")
        live.state = .needsInput
        live.dependencyRunIDs = [finished[0].id]
        try await store.save(finished + [live])
        _ = try await store.appendEvent(runID: finished[1].id, kind: .created, phase: "Queued")

        let coordinator = BotRunCoordinator(store: store)
        var pruned: [UUID] = []
        coordinator.pruneHandler = { pruned = $0 }
        await waitUntil { !pruned.isEmpty }

        XCTAssertEqual(pruned, [finished[1].id], "only the oldest run nothing depends on goes")
        XCTAssertEqual(coordinator.runs.count, BotRunCoordinator.retainedFinishedRuns + 2)
        XCTAssertTrue(coordinator.runs.contains { $0.id == finished[0].id })
        await settle()
        let prunedEvents = await store.loadEvents(runID: finished[1].id)
        XCTAssertTrue(prunedEvents.isEmpty)
    }

    func testLegacyEventsMoveToAnAppendOnlyLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([BotRunEvent(
            id: UUID(), runID: runID, sequence: 1, kind: .created,
            phase: "Queued", detail: nil, createdAt: Date())])
            .write(to: root.appendingPathComponent("bot-run-events.json"))

        let store = BotRunStore(root: root)
        _ = try await store.appendEvent(runID: runID, kind: .started, phase: "Starting")

        let events = await BotRunStore(root: root).loadEvents(runID: runID)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bot-run-events.json").path))
        let log = try String(contentsOf: root.appendingPathComponent("bot-run-events.jsonl"), encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 2)
    }

    /// A bot never edits the project in place: it works on a copy, and its changes reach the
    /// project only as a checked patch.
    func testRunWorksOnAPrivateCopyAndAppliesBackAsAPatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try ShellRunner.runProcess(
            executable: "/usr/bin/git", arguments: ["init", "-q"], workingDirectory: project, timeout: 30)
        let file = project.appendingPathComponent("a.txt")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)

        let service = BotComputerService(root: root.appendingPathComponent("computers"))
        let computer = try await service.prepare(
            profileID: "builder", name: "Builder", backend: .isolatedWorkspace)
        let runID = UUID()
        let work = try await service.prepareRunWorkspace(computerID: computer.id, runID: runID, seed: project)
        let base = try XCTUnwrap(work.baseTree)
        try "two\n".write(
            to: URL(fileURLWithPath: work.path).appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\n")
        let patch = try await service.patch(workPath: work.path, baseTree: base)
        XCTAssertTrue(patch.contains("+two"))
        let summary = try await service.applyChanges(workPath: work.path, baseTree: base, projectPath: project.path)
        XCTAssertTrue(summary.contains("a.txt"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "two\n")

        try await service.removeRunWorkspaces(runIDs: [runID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    @MainActor
    func testBotsCannotDriveBotsAndTheAssistantCanReachThem() {
        let botTools = Set(AgentSessionController.sessionTools(
            computerControlEnabled: false, botRun: true).map(\.name))
        XCTAssertFalse(botTools.contains("delegate_bot"))
        XCTAssertFalse(botTools.contains("bot_respond"))
        let assistantTools = AgentSessionController.sessionTools(computerControlEnabled: false)
        let routed = ToolRouter.select(from: assistantTools, for: "Have the Builder fix the login bug")
        XCTAssertTrue(routed.contains { $0.name == "delegate_bot" })
        XCTAssertTrue(routed.contains { $0.name == "bot_runs" })
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
