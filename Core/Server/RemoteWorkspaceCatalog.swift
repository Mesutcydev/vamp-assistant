import Foundation

/// Folders a paired Remote client may open or create on the Mac.
/// Creation stays inside the user's home (or an already-known project path).
enum RemoteWorkspaceCatalog {
    struct Item: Equatable, Sendable {
        var path: String
        var name: String
        var isCurrent: Bool
    }

    static func defaultCreateParent(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Documents/BeetCode", isDirectory: true)
    }

    static func list(
        currentPath: String?,
        lastPath: String?,
        records: [(path: String, updatedAt: Date)],
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [Item] {
        var seen = Set<String>()
        var ranked: [(path: String, updatedAt: Date)] = []
        func consider(_ path: String, updatedAt: Date) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let url = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
            let standardized = url.path
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !isBotComputerWorkspace(url, home: home),
                  !isSensitive(url, home: home),
                  seen.insert(standardized).inserted else { return }
            ranked.append((standardized, updatedAt))
        }
        if let lastPath { consider(lastPath, updatedAt: .distantFuture) }
        if let currentPath { consider(currentPath, updatedAt: .distantFuture) }
        for record in records { consider(record.path, updatedAt: record.updatedAt) }
        ranked.sort { $0.updatedAt > $1.updatedAt }
        let current = currentPath.flatMap {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        return ranked.map { item in
            Item(
                path: item.path,
                name: URL(fileURLWithPath: item.path).lastPathComponent,
                isCurrent: item.path == current)
        }
    }

    static func sanitizeFolderName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmed.count),
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed.first != "." else { return nil }
        return trimmed
    }

    static func resolveExisting(
        _ raw: String,
        home: URL,
        knownPaths: [String],
        fileManager: FileManager = .default
    ) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CatalogError.missingFolder
        }
        guard isAllowed(url, home: home, knownPaths: knownPaths) else {
            throw CatalogError.outsideHome
        }
        guard !isSensitive(url, home: home) else {
            throw CatalogError.sensitiveFolder
        }
        return url
    }

    static func createFolder(
        name: String,
        parentPath: String?,
        home: URL,
        knownPaths: [String],
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let name = sanitizeFolderName(name) else {
            throw CatalogError.invalidName
        }
        let parent: URL
        if let parentPath, !parentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let requested = URL(
                fileURLWithPath: (parentPath as NSString).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: requested.path, isDirectory: &isDirectory) {
                let defaultParent = defaultCreateParent(home: home).standardizedFileURL
                guard requested.path == defaultParent.path else {
                    throw CatalogError.missingFolder
                }
                try fileManager.createDirectory(at: requested, withIntermediateDirectories: true)
            }
            parent = try resolveExisting(parentPath, home: home, knownPaths: knownPaths, fileManager: fileManager)
        } else {
            parent = defaultCreateParent(home: home)
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            guard isAllowed(parent, home: home, knownPaths: knownPaths + [parent.path]) else {
                throw CatalogError.outsideHome
            }
            guard !isSensitive(parent, home: home) else {
                throw CatalogError.sensitiveFolder
            }
        }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: folder.path) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CatalogError.invalidName
            }
            return folder.standardizedFileURL
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder.standardizedFileURL
    }

    private static func isAllowed(_ url: URL, home: URL, knownPaths: [String]) -> Bool {
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        if real == homePath || real.hasPrefix(homePath.hasSuffix("/") ? homePath : homePath + "/") {
            return true
        }
        return knownPaths.contains {
            URL(fileURLWithPath: $0, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path == real
        }
    }

    /// Home itself plus credential and system trees a remote session must
    /// never open, even when they already appear in session history.
    /// iCloud Desktop/Documents live under Library; those project roots stay
    /// allowed so Remote can create `Documents/BeetCode`.
    private static let sensitiveHomeNames = [".ssh", ".gnupg", ".Trash"]

    static func isSensitive(_ url: URL, home: URL) -> Bool {
        let unresolved = url.standardizedFileURL
        let real = url.resolvingSymlinksInPath().standardizedFileURL
        let homeReal = home.resolvingSymlinksInPath().standardizedFileURL
        if unresolved.path == home.standardizedFileURL.path || real.path == homeReal.path {
            return true
        }
        if isUserProjectRoot(unresolved, home: home) || isUserProjectRoot(real, home: home) {
            return false
        }
        if isBeetCodeSupport(unresolved, home: home) || isBeetCodeSupport(real, home: home) {
            return false
        }
        for name in sensitiveHomeNames {
            let banned = home.appendingPathComponent(name, isDirectory: true)
            if isSameOrInside(real, parent: banned) || isSameOrInside(unresolved, parent: banned) {
                return true
            }
        }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        if isSameOrInside(real, parent: library) || isSameOrInside(unresolved, parent: library) {
            return true
        }
        return false
    }

    private static func isUserProjectRoot(_ url: URL, home: URL) -> Bool {
        for name in ["Documents", "Desktop", "Downloads", "Developer", "Projects", "Source"] {
            if isSameOrInside(url, parent: home.appendingPathComponent(name, isDirectory: true)) {
                return true
            }
        }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        if isSameOrInside(url, parent: library.appendingPathComponent("Mobile Documents", isDirectory: true)) {
            return true
        }
        if isSameOrInside(url, parent: library.appendingPathComponent("CloudStorage", isDirectory: true)) {
            return true
        }
        return false
    }

    private static func isBeetCodeSupport(_ url: URL, home: URL) -> Bool {
        isSameOrInside(
            url,
            parent: home.appendingPathComponent("Library/Application Support/BeetCode", isDirectory: true))
    }

    private static func isBotComputerWorkspace(_ url: URL, home: URL) -> Bool {
        isSameOrInside(
            url,
            parent: home.appendingPathComponent(
                "Library/Application Support/BeetCode/BotComputers",
                isDirectory: true))
    }

    private static func isSameOrInside(_ url: URL, parent: URL) -> Bool {
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        var parentPath = parent.resolvingSymlinksInPath().standardizedFileURL.path
        if parentPath.hasSuffix("/") { parentPath.removeLast() }
        return real == parentPath || real.hasPrefix(parentPath + "/")
    }

    enum CatalogError: Error, LocalizedError, Equatable {
        case missingFolder
        case outsideHome
        case invalidName
        case sensitiveFolder

        var errorDescription: String? {
            switch self {
            case .missingFolder: "That folder is not on this Mac."
            case .outsideHome: "Remote sessions can only open folders inside your home directory or a project Vamp Assistant already knows."
            case .invalidName: "Use a short folder name without slashes or a leading dot."
            case .sensitiveFolder: "Remote sessions cannot open your home folder, Library, Trash, or credential directories such as .ssh."
            }
        }
    }
}
