import Foundation

/// Apple Core AI backend for imported `.aimodel` resource packs.
///
/// Core AI is an OS-27 runtime. Keeping the SDK-facing executable behind this
/// process boundary lets BeetCode retain its macOS 15 deployment target and
/// Xcode 26 build while becoming functional as soon as Apple's `llm-runner`
/// is installed (or bundled by a future Xcode-27 release build). Generation
/// stays local and never falls back to a remote provider.
final class CoreAIEngine: LLMEngine, @unchecked Sendable {
    enum CoreAIError: Error, LocalizedError, Equatable {
        case unsupportedOS
        case runnerMissing
        case invalidPack
        case notLoaded
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Apple Core AI requires macOS 27 or later. MLX and GGUF models remain available on this Mac."
            case .runnerMissing:
                return "Core AI support is ready, but Apple's llm-runner is not installed. Build it with Xcode 27 from apple/coreai-models and place it in BeetCode/Application Support/Tools."
            case .invalidPack:
                return "This is not a complete Core AI pack. It must contain metadata.json and at least one .aimodel or .aimodelc resource."
            case .notLoaded:
                return "No Core AI model is loaded."
            case .generationFailed(let detail):
                return "Core AI generation failed: \(detail)"
            }
        }
    }

    enum Planner {
        static func resourceDirectory(in root: URL) -> URL? {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return nil }
            var metadataDirectories: [URL] = []
            var assetDirectories = Set<URL>()
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 20_000 { return nil }
                let lower = url.lastPathComponent.lowercased()
                if lower == "metadata.json" {
                    metadataDirectories.append(url.deletingLastPathComponent())
                } else if lower.hasSuffix(".aimodel") || lower.hasSuffix(".aimodelc") {
                    assetDirectories.insert(url.deletingLastPathComponent())
                }
            }
            return metadataDirectories.first(where: { metadata in
                assetDirectories.contains(metadata)
                    || assetDirectories.contains(where: { $0.path.hasPrefix(metadata.path + "/") })
            })
        }

        static func runnerCandidates(environment: [String: String], home: String, bundle: Bundle) -> [URL] {
            var paths: [String] = []
            if let override = environment["BEETCODE_COREAI_RUNNER"], !override.isEmpty {
                paths.append(override)
            }
            if let bundled = bundle.url(forAuxiliaryExecutable: "llm-runner")?.path {
                paths.append(bundled)
            }
            paths += [
                "\(home)/Library/Application Support/BeetCode/Tools/llm-runner",
                "/opt/homebrew/bin/llm-runner",
                "/usr/local/bin/llm-runner",
            ]
            var seen = Set<String>()
            return paths.filter { seen.insert($0).inserted }.map(URL.init(fileURLWithPath:))
        }

        static func prompt(from turns: [ChatTurn]) -> String {
            turns.map { turn in
                let role: String
                switch turn.role {
                case .system: role = "System"
                case .user: role = "User"
                case .assistant: role = "Assistant"
                case .tool: role = "Tool"
                }
                return "\(role): \(turn.content)"
            }.joined(separator: "\n\n") + "\n\nAssistant:"
        }

        static func generatedText(from output: String) -> String? {
            guard let start = output.range(of: "Generating...\n") else { return nil }
            var text = String(output[start.upperBound...])
            if let summary = text.range(of: "\n⏱️  Performance Summary:") {
                text = String(text[..<summary.lowerBound])
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private let lock = NSLock()
    private var modelID: String?
    private var resources: URL?
    private var runner: URL?
    private var history: [ChatTurn] = []
    private var cancelled = false
    private var statsState = EngineStats()

    var loadedModelID: String? { get async { withLock { modelID } } }
    var stats: EngineStats { get async { withLock { statsState } } }

    func load(directory: URL, modelID: String, diskBytes: Int64) async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            throw CoreAIError.unsupportedOS
        }
        guard let resources = Planner.resourceDirectory(in: directory) else {
            throw CoreAIError.invalidPack
        }
        let executable = Planner.runnerCandidates(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            bundle: .main
        ).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        guard let executable else { throw CoreAIError.runnerMissing }
        withLock {
            self.modelID = modelID
            self.resources = resources
            self.runner = executable
            self.history = []
            self.cancelled = false
            self.statsState = EngineStats()
        }
    }

    func unload() async {
        cancelGenerationLocked()
        withLock {
            modelID = nil
            resources = nil
            runner = nil
            history = []
            statsState = EngineStats()
        }
    }

    func reset() async { withLock { history = [] } }

    func rebaseConversation(to turns: [ChatTurn]) async -> SemanticRebaseResult {
        withLock { history = turns }
        return SemanticRebaseResult(installedHistory: true)
    }

    func stream(
        adding turns: [ChatTurn], maxTokens: Int?, temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let snapshot: (URL, URL, [ChatTurn])? = withLock {
            guard let runner, let resources else { return nil }
            cancelled = false
            history.append(contentsOf: turns)
            return (runner, resources, history)
        }
        return AsyncThrowingStream { continuation in
            guard let (runner, resources, transcript) = snapshot else {
                continuation.finish(throwing: CoreAIError.notLoaded)
                return
            }
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("beetcode-coreai-\(UUID().uuidString).txt")
                defer { try? FileManager.default.removeItem(at: temp) }
                do {
                    try Data(Planner.prompt(from: transcript).utf8).write(to: temp, options: .atomic)
                    let result = try ShellRunner.runProcess(
                        executable: runner.path,
                        arguments: [
                            "--model", resources.path,
                            "--prompt-file", temp.path,
                            "--max-tokens", String(max(1, maxTokens ?? 1_024)),
                            "--temperature", String(max(0, temperature ?? 0.7)),
                            "--warmup", "default",
                        ],
                        workingDirectory: resources,
                        timeout: 15 * 60,
                        maxOutputBytes: 8 * 1_024 * 1_024,
                        cancelCheck: { [weak self] in self?.withLock { self?.cancelled ?? true } ?? true })
                    if self.withLock({ self.cancelled }) {
                        continuation.finish(throwing: CancellationError())
                    } else if result.failed {
                        continuation.finish(throwing: CoreAIError.generationFailed(result.output))
                    } else if let text = Planner.generatedText(from: result.output) {
                        self.withLock {
                            self.history.append(ChatTurn(role: .assistant, content: text))
                            self.statsState.generatedTokens = max(1, text.count / 4)
                            self.statsState.usageSerial &+= 1
                        }
                        continuation.yield(text)
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CoreAIError.generationFailed("The runner returned no generated text."))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.cancelGenerationLocked()
                task.cancel()
            }
        }
    }

    func streamReplay(
        _ turns: [ChatTurn], maxTokens: Int?, temperature: Double?
    ) -> AsyncThrowingStream<String, Error> {
        let original = withLock { history }
        withLock { history = [] }
        let stream = stream(adding: turns, maxTokens: maxTokens, temperature: temperature)
        withLock { history = original }
        return stream
    }

    func cancelGeneration() async { cancelGenerationLocked() }

    private func cancelGenerationLocked() { withLock { cancelled = true } }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
