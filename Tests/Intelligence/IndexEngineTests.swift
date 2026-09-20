import Foundation
import XCTest
@testable import BeetCode

/// Phase 4 — Incremental indexing + file watching. Every test runs the real
/// engine against a real temp workspace; the watcher test uses real FSEvents.
final class IndexEngineTests: XCTestCase {

    /// TempWorkspace removes its directory on deinit — engine stores must
    /// stay alive for the whole test, so they're retained here.
    private var retainedStores: [TempWorkspace] = []

    private func makeEngine(_ ws: TempWorkspace) throws -> IndexEngine {
        let storeDir = TempWorkspace()
        retainedStores.append(storeDir)
        IntelligenceStoreLayout.overrideRoot = storeDir.url
        let snapshotStore = WorkspaceSnapshotStore()
        snapshotStore.overrideDirectory = storeDir.url.appendingPathComponent("snapshots")
        let identity = WorkspaceIdentity.resolve(root: ws.url)
        let graph = try SymbolGraph(store: SQLiteStore(
            url: storeDir.url.appendingPathComponent("graph.sqlite")))
        let journal = try InvalidationJournal(store: SQLiteStore(
            url: storeDir.url.appendingPathComponent("metadata.sqlite")))
        return IndexEngine(identity: identity, graph: graph, journal: journal,
                           snapshotStore: snapshotStore)
    }

    private let fileA = """
    import Foundation
    struct Alpha {
        func compute() { helper() }
        private func helper() {}
    }
    """

    private let fileB = """
    import Foundation
    struct Beta {
        func run() { Alpha().compute() }
    }
    """

    func testFullIndexParsesSupportedFilesOnly() async throws {
        let ws = TempWorkspace()
        ws.write(fileA, to: "Sources/Alpha.swift")
        ws.write(fileB, to: "Sources/Beta.swift")
        ws.write("# readme", to: "README.md")
        ws.write("binary", to: "data.dat")

        let engine = try makeEngine(ws)
        let stats = try await engine.fullIndex()
        XCTAssertEqual(stats.parsed, 2)
        XCTAssertEqual(stats.added, 4) // all files recorded, parsed or not

        let graph = await engine.graphHandle
        let compute = try graph.findSymbols(named: "compute")
        XCTAssertEqual(compute.count, 1)
    }

    func testIncrementalUpdateOnlyReprocessesChangedFile() async throws {
        let ws = TempWorkspace()
        ws.write(fileA, to: "Sources/Alpha.swift")
        ws.write(fileB, to: "Sources/Beta.swift")
        let engine = try makeEngine(ws)
        try await engine.fullIndex()

        let graph = await engine.graphHandle
        let alphaIDBefore = try graph.findSymbols(named: "Alpha").first?.id

        // Change ONLY Beta.
        ws.write(fileB + "\n// touched\n", to: "Sources/Beta.swift")
        let stats = try await engine.incrementalUpdate()
        XCTAssertEqual(stats.modified, 1)
        XCTAssertEqual(stats.added, 0)
        XCTAssertEqual(stats.deleted, 0)

        // Alpha's symbol identity untouched; Beta re-indexed.
        XCTAssertEqual(try graph.findSymbols(named: "Alpha").first?.id, alphaIDBefore)
    }

    func testIncrementalDelete() async throws {
        let ws = TempWorkspace()
        ws.write(fileA, to: "Alpha.swift")
        ws.write(fileB, to: "Beta.swift")
        let engine = try makeEngine(ws)
        try await engine.fullIndex()

        try FileManager.default.removeItem(at: ws.url(for: "Alpha.swift"))
        let stats = try await engine.incrementalUpdate()
        XCTAssertEqual(stats.deleted, 1)
        let graph = await engine.graphHandle
        XCTAssertTrue(try graph.findSymbols(named: "Alpha").isEmpty)
        // Beta's dangling call edge was removed with Alpha's nodes.
        let run = try graph.findSymbols(named: "run").first!
        XCTAssertTrue(try graph.outgoingEdges(from: run.id, kind: .calls).isEmpty)
    }

    func testIncrementalRename() async throws {
        let ws = TempWorkspace()
        ws.write(fileA, to: "Old/Alpha.swift")
        let engine = try makeEngine(ws)
        try await engine.fullIndex()

        ws.write(fileA, to: "New/Alpha.swift")
        try FileManager.default.removeItem(at: ws.url(for: "Old/Alpha.swift"))
        let stats = try await engine.incrementalUpdate()
        XCTAssertEqual(stats.renamed, 1)
        XCTAssertEqual(stats.deleted, 0)
        // Descriptor embeds the path: the renamed file re-indexes under its
        // new identity, and the journal records the rename honestly.
        let graph = await engine.graphHandle
        let alpha = try graph.findSymbols(named: "Alpha").first
        XCTAssertTrue(alpha?.descriptor?.contains("New/Alpha.swift") == true)
    }

    func testInvalidationJournalRecordsChanges() async throws {
        let ws = TempWorkspace()
        ws.write(fileA, to: "Alpha.swift")
        let engine = try makeEngine(ws)
        try await engine.fullIndex()

        ws.write(fileA + "\n// v2\n", to: "Alpha.swift")
        try await engine.incrementalUpdate()

        // Journal is the deterministic staleness signal: Phase 8 knowledge
        // depending on Alpha.swift@oldHash goes stale without any LLM.
        let storeDir = IntelligenceStoreLayout.overrideRoot!
        let journal = try InvalidationJournal(store: SQLiteStore(
            url: storeDir.appendingPathComponent("metadata.sqlite")))
        let entries = try journal.entries(forPath: "Alpha.swift")
        XCTAssertEqual(entries.map(\.kind), [.added, .modified])
        XCTAssertNotEqual(entries[0].newHash, entries[1].newHash)
        XCTAssertEqual(entries[1].oldHash, entries[0].newHash)
    }

    func testNoChangesMeansEmptyDelta() async throws {
        let ws = TempWorkspace()
        ws.write(fileA, to: "Alpha.swift")
        let engine = try makeEngine(ws)
        try await engine.fullIndex()
        let stats = try await engine.incrementalUpdate()
        XCTAssertTrue(stats.added == 0 && stats.modified == 0
                      && stats.deleted == 0 && stats.renamed == 0)
    }
}
