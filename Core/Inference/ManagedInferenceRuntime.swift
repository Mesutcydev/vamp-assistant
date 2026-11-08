import Foundation

/// Independently installed runtimes. Compatibility runtimes are selected by
/// model ID or GGUF architecture; experimental runtimes remain opt-in. A newer
/// binary never replaces the Prism GGUF runtime globally.
struct ManagedInferenceRuntime: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case omlx, mlxfast, llamaMetal, llamaCompatibility

        var label: String {
            switch self {
            case .omlx: "oMLX"
            case .mlxfast: "MLXFast Bonsai"
            case .llamaMetal: "llama.cpp Metal"
            case .llamaCompatibility: "llama.cpp (model compatibility)"
            }
        }

        var preferenceKey: String { "managedInference.\(rawValue).enabled" }
        var supportedOnThisMac: Bool {
            // Both 27B experiments exceeded the tested 16 GB device's
            // memory budget on longer replies. oMLX uses small checkpoints.
            self == .omlx || self == .llamaCompatibility
                || ProcessInfo.processInfo.physicalMemory >= 24 * 1024 * 1024 * 1024
        }
        var enabled: Bool {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
            guard supportedOnThisMac else { return false }
            return self == .llamaCompatibility || UserDefaults.standard.bool(forKey: preferenceKey)
        }
    }

    struct Manifest: Codable, Sendable {
        var version: Int
        var runtimes: [ManagedInferenceRuntime]
    }

    /// Ignore unsupported or malformed entries without hiding the other
    /// installed runtimes when a newer app adds another kind.
    private struct ReadableManifest: Decodable {
        struct Entry: Decodable {
            let runtime: ManagedInferenceRuntime?
            init(from decoder: Decoder) throws {
                runtime = try? ManagedInferenceRuntime(from: decoder)
            }
        }
        let version: Int
        let runtimes: [Entry]
    }

    var kind: Kind
    var revision: String
    var executable: String
    var models: [String]
    var visionModels: [String]
    /// Architecture rules let imported models use a compatible runtime even
    /// when their catalog IDs differ from the installer's examples.
    var architectures: [String]? = nil
    /// Prism PQ2_0/PTQ1_0 need fork kernels even when the backbone is Qwen.
    var fileTypes: [Int]? = nil

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Runtimes", isDirectory: true)
    }

    static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Runtimes", isDirectory: true)
    }

    func executableURL(root: URL = Self.root) -> URL? {
        // Release helpers are signed as part of the application. Prefer them
        // over a separately installed copy with the same relative path.
        if root == Self.root, let bundled = Self.bundledRoot,
           let url = executableURL(root: bundled) { return url }
        guard !executable.hasPrefix("/"), !executable.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(executable).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func installed(root: URL = Self.root) -> [Self] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(ReadableManifest.self, from: data),
              manifest.version == 1 else { return [] }
        return manifest.runtimes.compactMap(\.runtime).filter { $0.executableURL(root: root) != nil }
    }

    static func available() -> [Self] {
        let bundled = bundledRoot.map { installed(root: $0) } ?? []
        return bundled + installed()
    }

    static func resolve(kind: Kind, modelID: String) -> Self? {
        guard kind.enabled else { return nil }
        return available().first { $0.kind == kind && $0.models.contains(modelID) }
    }

    /// Packed-format requirements come first, then exact checkpoints and
    /// architecture rules. The
    /// manifest order breaks ties, so an installer can choose a preferred
    /// version without affecting unrelated models or experimental runtimes.
    static func selectGGUFCompatibility(
        modelID: String, architecture: String?, fileType: Int? = nil, runtimes: [Self]
    ) -> Self? {
        let candidates = runtimes.filter { $0.kind == .llamaCompatibility }
        if let fileType, [141, 142, 143].contains(fileType) {
            // Never route packed Prism weights to an upstream Qwen runtime.
            return candidates.first { $0.fileTypes?.contains(fileType) == true }
        }
        if let exact = candidates.first(where: { $0.models.contains(modelID) }) { return exact }
        guard let architecture, !architecture.isEmpty else { return nil }
        return candidates.first { runtime in
            runtime.architectures?.contains {
                $0.caseInsensitiveCompare(architecture) == .orderedSame
            } == true
        }
    }

    static func resolveGGUFCompatibility(modelID: String, architecture: String?, fileType: Int? = nil) -> Self? {
        guard Kind.llamaCompatibility.enabled else { return nil }
        return selectGGUFCompatibility(modelID: modelID, architecture: architecture, fileType: fileType, runtimes: available())
    }
}
