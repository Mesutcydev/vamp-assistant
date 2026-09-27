import Foundation

/// Optional, independently installed runtimes. Only checkpoint IDs verified by
/// the installer are eligible; a newer binary never replaces the Prism GGUF
/// runtime globally. The manifest contains no credentials or prompts.
struct ManagedInferenceRuntime: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case omlx, mlxfast, llamaMetal

        var label: String {
            switch self {
            case .omlx: "oMLX"
            case .mlxfast: "MLXFast Bonsai"
            case .llamaMetal: "llama.cpp Metal"
            }
        }

        var preferenceKey: String { "managedInference.\(rawValue).enabled" }
        var supportedOnThisMac: Bool {
            // Both 27B experiments exceeded the tested 16 GB device's
            // memory budget on longer replies. oMLX uses small checkpoints.
            self == .omlx || ProcessInfo.processInfo.physicalMemory >= 24 * 1024 * 1024 * 1024
        }
        var enabled: Bool {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
            return supportedOnThisMac && UserDefaults.standard.bool(forKey: preferenceKey)
        }
    }

    struct Manifest: Codable, Sendable {
        var version: Int
        var runtimes: [ManagedInferenceRuntime]
    }

    var kind: Kind
    var revision: String
    var executable: String
    var models: [String]
    var visionModels: [String]

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BeetCode/Runtimes", isDirectory: true)
    }

    func executableURL(root: URL = Self.root) -> URL? {
        guard !executable.hasPrefix("/"), !executable.split(separator: "/").contains("..") else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(executable).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    static func installed(root: URL = Self.root) -> [Self] {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1 else { return [] }
        return manifest.runtimes.filter { $0.executableURL(root: root) != nil }
    }

    static func resolve(kind: Kind, modelID: String) -> Self? {
        guard kind.enabled else { return nil }
        return installed().first { $0.kind == kind && $0.models.contains(modelID) }
    }
}
