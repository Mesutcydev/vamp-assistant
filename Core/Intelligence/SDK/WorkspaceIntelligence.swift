import Foundation

/// Facade used by the agent prompt inject and the optional inspector:
/// index the workspace, then compile a bounded context packet.
final class WorkspaceIntelligence: @unchecked Sendable {

    let identity: WorkspaceIdentity
    let root: URL

    private let snapshotStore: WorkspaceSnapshotStore

    init(workspaceRoot: URL,
                snapshotStore: WorkspaceSnapshotStore = .shared) {
        self.root = workspaceRoot
        self.identity = WorkspaceIdentity.resolve(root: workspaceRoot)
        self.snapshotStore = snapshotStore
    }

    // MARK: Store handles

    private var graphURL: URL {
        IntelligenceStoreLayout.graphDatabase(for: identity.workspaceID)
    }

    private var metadataURL: URL {
        IntelligenceStoreLayout.metadataDatabase(for: identity.workspaceID)
    }

    func graph() throws -> SymbolGraph {
        try SymbolGraph(store: SQLiteStore(url: graphURL))
    }

    func knowledgeStore() throws -> KnowledgeStore {
        try KnowledgeStore(store: SQLiteStore(url: metadataURL))
    }

    func entityStore() throws -> EntityStore {
        try EntityStore(store: SQLiteStore(url: graphURL))
    }

    func pinStore() throws -> ContextPackPinStore {
        try ContextPackPinStore(store: SQLiteStore(url: metadataURL))
    }

    // MARK: Indexing

    /// First or full re-index. Returns per-kind stats.
    @discardableResult
    func index() async throws -> IndexEngine.UpdateStats {
        try await makeEngine().fullIndex()
    }

    /// Delta-driven update; falls back to a full index without a baseline.
    @discardableResult
    func update() async throws -> IndexEngine.UpdateStats {
        try await makeEngine().incrementalUpdate()
    }

    private func makeEngine() throws -> IndexEngine {
        IndexEngine(
            identity: identity,
            graph: try graph(),
            journal: try InvalidationJournal(store: SQLiteStore(url: metadataURL)),
            snapshotStore: snapshotStore,
            entityStore: try entityStore())
    }

    // MARK: Read APIs

    /// The compact project capsule, rendered within its token budget.
    func overview() throws -> String {
        guard let snapshot = snapshotStore.loadLatest(workspaceID: identity.workspaceID) else {
            return "workspace not indexed"
        }
        let stale = (try? knowledgeStore().allRecords().filter {
            $0.freshness != .fresh
        }.count) ?? 0
        return try CapsuleGenerator.generate(
            identity: identity, snapshot: snapshot, graph: graph(),
            staleKnowledgeCount: stale).rendered()
    }

    /// Budgeted context packet for a task. `pinnedPacks` reweight retrieval
    /// (Phase 18) without growing the budget.
    func context(
        for task: String, budgetTokens: Int = 4_000,
        sessionID: UUID? = nil
    ) throws -> ContextPacket {
        let snapshot = snapshotStore.loadLatest(workspaceID: identity.workspaceID)
        let graph = try graph()
        let knowledge = FileManager.default.fileExists(atPath: metadataURL.path)
            ? try? knowledgeStore() : nil
        let pins = (try? pinStore().pinnedPacks(
            workspaceID: identity.workspaceID, sessionID: sessionID)) ?? []
        let compiler = ContextCompiler(
            graph: graph, knowledge: knowledge,
            capsuleProvider: {
                if let snapshot {
                    return try CapsuleGenerator.generate(
                        identity: self.identity, snapshot: snapshot, graph: graph)
                }
                return ProjectCapsule(
                    projectName: self.root.lastPathComponent, languages: [],
                    structure: [], hubSymbols: [], branch: nil, commit: nil,
                    fileCount: 0, symbolCount: 0, edgeCount: 0,
                    snapshotID: UUID(), generatedAt: Date(), staleKnowledgeCount: 0)
            },
            sourceLoader: { path, start, end in
                guard let url = PathSafety.resolve(
                    root: URL(fileURLWithPath: self.identity.canonicalPath),
                    relative: path),
                    let text = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                let lines = text.components(separatedBy: "\n")
                guard start >= 1, end <= lines.count else { return nil }
                return lines[(start - 1)..<end].joined(separator: "\n")
            })
        return try compiler.compileContext(
            task: AgentTask(text: task),
            budget: ContextBudget(
                contextWindowTokens: budgetTokens + 6_000, maxOutputTokens: 4_000,
                systemPromptTokens: 1_000, conversationTokens: 500,
                safetyMarginTokens: 500),
            pinnedPacks: pins)
    }

    /// Lexical symbol search (substring, case-insensitive).
    func searchSymbols(matching query: String, limit: Int = 20) throws -> [SymbolGraph.Node] {
        try graph().searchSymbols(matching: query, limit: limit)
    }
}
