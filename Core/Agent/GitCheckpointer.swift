import Darwin
import Foundation

/// Snapshots the workspace working tree before an approved edit batch, without
/// touching the repository's real index. Uses a temporary index file:
///
///     GIT_INDEX_FILE=<tmp> git add -A && git write-tree
///
/// which yields a tree SHA referencing the exact pre-edit state (including
/// untracked files). Restoring runs `git read-tree -u --reset <sha>` on the
/// real index so tracked files — and files the agent added — return to the
/// snapshot, then the *prior* index state is put back so the user's staged
/// work survives. Checkpoint metadata is stored with the session so undo
/// survives relaunch.
struct GitCheckpointer {

    enum CheckpointError: Error, LocalizedError {
        case noRepository
        case gitFailed(String)
        case foreignTree(String)

        var errorDescription: String? {
            switch self {
            case .noRepository:
                return "The workspace is not a git repository; checkpoints are unavailable."
            case .gitFailed(let output):
                return "git checkpoint failed: \(output)"
            case .foreignTree(let sha):
                return "Checkpoint tree \(sha) does not belong to this repository; refusing to restore."
            }
        }
    }

    let workspace: Workspace

    /// Serializes snapshot/restore per workspace so concurrent agent runs on
    /// the same folder cannot corrupt each other's checkpoints.
    private static let workspaceLocks: NSLock = NSLock()
    // All access to this registry happens under `workspaceLocks`, which
    // is what makes it safe despite the static mutable state.
    private static nonisolated(unsafe) var locksByRoot: [String: NSLock] = [:]

    private var operationLock: NSLock {
        let root = workspace.root.standardizedFileURL.path
        Self.workspaceLocks.lock()
        defer { Self.workspaceLocks.unlock() }
        if let existing = Self.locksByRoot[root] { return existing }
        let created = NSLock()
        Self.locksByRoot[root] = created
        return created
    }

    /// Git override variables that must never leak from the app's own
    /// environment into checkpoint git commands.
    private static let gitOverrideKeys: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_SHALLOW_FILE",
    ]

    /// Returns false when the workspace is not a git repository (checkpointing
    /// silently disabled, surfaced by `snapshot` errors only when attempted).
    func hasRepository() -> Bool {
        let result = git(["rev-parse", "--is-inside-work-tree"])
        return result?.trimmedOutput.hasPrefix("true") == true
    }

    /// Creates a snapshot of the current working tree (tracked + untracked).
    /// The tree is pinned under a local ref so `git gc` cannot collect it
    /// before the session is restored.
    func snapshot(summary: String) throws -> SessionCheckpoint {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard hasRepository() else { throw CheckpointError.noRepository }

        let tempIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempIndex) }

        guard let addResult = git(["add", "-A"], environment: ["GIT_INDEX_FILE": tempIndex.path]),
              addResult.exitCode == 0
        else { throw CheckpointError.gitFailed("git add -A failed") }

        guard let treeResult = git(["write-tree"], environment: ["GIT_INDEX_FILE": tempIndex.path]) else {
            throw CheckpointError.gitFailed("git write-tree failed")
        }
        guard treeResult.exitCode == 0 else {
            throw CheckpointError.gitFailed(treeResult.trimmedOutput)
        }

        let treeSHA = treeResult.trimmedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard treeSHA.count == 40 || treeSHA.count == 64 else {
            throw CheckpointError.gitFailed("unexpected tree SHA: \(treeSHA)")
        }

        // Pin the tree under a local ref so garbage collection keeps it alive
        // for the lifetime of the checkpoint.
        let refName = "refs/beetcode/checkpoints/\(UUID().uuidString)"
        if let pinResult = git(["update-ref", refName, treeSHA]), pinResult.exitCode != 0 {
            throw CheckpointError.gitFailed(pinResult.trimmedOutput)
        }

        return SessionCheckpoint(
            id: UUID(),
            treeSHA: treeSHA,
            createdAt: Date(),
            summary: summary,
            refName: refName)
    }

    /// Deletes one checkpoint pin ref. Refuses anything outside the
    /// `refs/beetcode/checkpoints/` namespace so a crafted session record can
    /// never delete user branches or tags. Returns false when the ref could
    /// not be removed (missing repo, moved workspace, git unavailable) —
    /// pruning is best-effort and never throws.
    @discardableResult
    func deletePinRef(_ refName: String) -> Bool {
        guard Self.isCheckpointRefName(refName) else { return false }
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let result = git(["update-ref", "-d", refName]), result.exitCode == 0 else {
            return false
        }
        return true
    }

    /// Pin refs under `refs/beetcode/checkpoints/`, keyed by ref name with the
    /// tree SHA each points at.
    func pinnedCheckpointRefs() -> [String: String] {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard hasRepository(),
              let result = git([
                "for-each-ref", "--format=%(refname) %(objectname)",
                "refs/beetcode/checkpoints/",
              ]),
              result.exitCode == 0
        else { return [:] }
        var refs: [String: String] = [:]
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.isCheckpointRefName(parts[0]) else { continue }
            refs[parts[0]] = parts[1]
        }
        return refs
    }

    /// Removes every pin ref recorded by a deleted session's checkpoints.
    /// Never throws: a moved workspace or unavailable git must not block the
    /// deletion itself. Legacy checkpoints (nil `refName`) are skipped here;
    /// their refs are handled by `sweepOrphanedPins`.
    static func prunePins(checkpoints: [SessionCheckpoint], workspacePath: String) {
        let refNames = checkpoints.compactMap(\.refName).filter(Self.isCheckpointRefName)
        guard !refNames.isEmpty, !workspacePath.isEmpty else { return }
        let checkpointer = GitCheckpointer(
            workspace: Workspace(root: URL(fileURLWithPath: workspacePath)))
        for refName in refNames {
            checkpointer.deletePinRef(refName)
        }
    }

    /// Deletes pin refs in `workspacePath` whose tree is not referenced by any
    /// surviving session. Matching by the pinned tree (not the ref name) keeps
    /// legacy refs — created before `SessionCheckpoint.refName` existed — as
    /// long as their session still exists, and cleans up refs left behind by
    /// crashes between snapshot and session save. Returns the deleted refs.
    @discardableResult
    static func sweepOrphanedPins(
        workspacePath: String,
        referencedTreeSHAs: Set<String>
    ) -> [String] {
        guard !workspacePath.isEmpty else { return [] }
        let checkpointer = GitCheckpointer(
            workspace: Workspace(root: URL(fileURLWithPath: workspacePath)))
        var deleted: [String] = []
        for (refName, treeSHA) in checkpointer.pinnedCheckpointRefs()
        where !referencedTreeSHAs.contains(treeSHA) {
            if checkpointer.deletePinRef(refName) { deleted.append(refName) }
        }
        return deleted
    }

    private static func isCheckpointRefName(_ name: String) -> Bool {
        name.hasPrefix("refs/beetcode/checkpoints/")
    }

    /// Restores the working tree to a checkpoint state. Refuses foreign trees,
    /// preserves the repository's prior index state, and removes only
    /// validated untracked paths absent from the checkpoint — never following
    /// a symlink outside the workspace during cleanup.
    func restore(_ checkpoint: SessionCheckpoint) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard hasRepository() else { throw CheckpointError.noRepository }

        // 1. Validate the tree belongs to this repository before touching
        //    anything: a tree SHA from another repo must be refused.
        guard let verifyResult = git(["cat-file", "-e", "\(checkpoint.treeSHA)^{tree}"]),
              verifyResult.exitCode == 0
        else { throw CheckpointError.foreignTree(checkpoint.treeSHA) }

        // 2. Preserve the real index so the user's staged state survives.
        let savedIndex = FileManager.default.temporaryDirectory
            .appendingPathComponent("beetcode-index-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: savedIndex) }
        var indexWasPreserved = false
        let preservedIndexURL = indexPath()
        if let preservedIndexURL,
           FileManager.default.fileExists(atPath: preservedIndexURL.path) {
            do {
                try FileManager.default.copyItem(at: preservedIndexURL, to: savedIndex)
                indexWasPreserved = true
            } catch {
                // Non-fatal: continue without index preservation.
            }
        }

        // 3. Reset the working tree to the snapshot.
        guard let result = git(["read-tree", "-u", "--reset", checkpoint.treeSHA]) else {
            throw CheckpointError.gitFailed("git read-tree failed")
        }
        guard result.exitCode == 0 else {
            throw CheckpointError.gitFailed(result.trimmedOutput)
        }

        // 4. Put the prior index back: the worktree now matches the snapshot
        //    while the user's staged changes remain visible as such.
        if indexWasPreserved, let restoredIndexURL = indexPath() {
            try? FileManager.default.removeItem(at: restoredIndexURL)
            try? FileManager.default.copyItem(at: savedIndex, to: restoredIndexURL)
        }

        // 5. `read-tree -u` restores tracked files but leaves paths that
        //    became untracked after the snapshot. Remove only untracked paths
        //    absent from the checkpoint tree; never use broad `git clean` on a
        //    user's folder, and never follow a symlink out of the workspace.
        let checkpointPaths = Set(
            (git(["ls-tree", "-r", "-z", "--name-only", checkpoint.treeSHA])?.output
                .split(separator: "\0")
                .map(String.init)) ?? [])
        let currentUntracked = git(["ls-files", "--others", "--exclude-standard", "-z"])?.output
            .split(separator: "\0")
            .map(String.init) ?? []
        for path in currentUntracked where !checkpointPaths.contains(path) {
            // Validate each path through the workspace authority so cleanup
            // cannot reach outside via a symlinked parent.
            guard let resolved = try? workspace.resolve(path, access: .write).url else { continue }
            try? FileManager.default.removeItem(at: resolved)
        }
    }

    // MARK: Process plumbing

    /// Absolute URL of the repository's index file. `git rev-parse --git-path
    /// index` prints a path relative to the repository (for example
    /// `.git/index`), so resolving it against the process cwd would point at
    /// the wrong repository — or nothing at all when the app is launched from
    /// Finder. Always anchor it to the workspace root.
    private func indexPath() -> URL? {
        guard let raw = git(["rev-parse", "--git-path", "index"])?.trimmedOutput,
              !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw).standardizedFileURL
        }
        return URL(fileURLWithPath: raw, relativeTo: workspace.root).standardizedFileURL
    }

    private struct GitResult {
        let exitCode: Int32
        let output: String

        var trimmedOutput: String {
            output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Hard wall-clock cap for every git invocation: a hung git (locked repo,
    /// network filesystem) must never block the agent loop.
    private static let gitTimeout: TimeInterval = 30

    private func git(_ arguments: [String], environment: [String: String] = [:]) -> GitResult? {
        // Sanitized environment bound to this workspace: ambient Git override
        // variables (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, …) exported by
        // the launching terminal must never redirect our git commands.
        var sanitized = ProcessInfo.processInfo.environment
        for key in Self.gitOverrideKeys { sanitized.removeValue(forKey: key) }
        sanitized["GIT_OPTIONAL_LOCKS"] = "0"
        sanitized.merge(environment) { _, new in new }

        // One shared, time-bounded process runner (posix_spawn + waitpid
        // polling + group kill) — a hung git can never block the loop.
        guard let result = try? ShellRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: arguments,
            workingDirectory: workspace.root,
            environment: sanitized,
            timeout: Self.gitTimeout)
        else { return nil }
        if result.timedOut {
            return GitResult(exitCode: -1, output: "git timed out after \(Int(Self.gitTimeout))s")
        }
        return GitResult(exitCode: result.exitCode, output: result.output)
    }

}