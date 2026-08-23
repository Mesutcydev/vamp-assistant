import AppKit
import Foundation
import UniformTypeIdentifiers

struct RemoteSharedFile: Equatable, Sendable {
    let name: String
    let size: Int
    let modifiedAt: Date
}

/// Explicit, user-initiated exchange surface for paired remote clients.
/// Files are kept in a visible Downloads folder so nothing is hidden inside
/// the app container and the Mac owner can remove them at any time.
@MainActor
final class RemoteSharingStore {
    static let defaultDirectoryName = "BeetCode Remote"

    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        self.directoryURL = directoryURL
            ?? downloads.appendingPathComponent(Self.defaultDirectoryName, isDirectory: true)
    }

    func clipboardText() -> String {
        String((NSPasteboard.general.string(forType: .string) ?? "").prefix(RemoteSessionHost.maxClipboardCharacters))
    }

    func setClipboardText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(text.prefix(RemoteSessionHost.maxClipboardCharacters)), forType: .string)
    }

    func files() throws -> [RemoteSharedFile] {
        try ensureDirectory()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .compactMap { url -> RemoteSharedFile? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return RemoteSharedFile(
                name: url.lastPathComponent,
                size: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
        .prefix(50)
        .map { $0 }
    }

    func save(_ data: Data, suggestedName: String) throws -> RemoteSharedFile {
        guard !data.isEmpty, data.count <= RemoteSessionHost.maxRemoteFileBytes else {
            throw RemoteSharingError.invalidFile
        }
        try ensureDirectory()
        let safeName = Self.sanitizeFileName(suggestedName)
        let destination = uniqueDestination(for: safeName)
        try data.write(to: destination, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return RemoteSharedFile(name: destination.lastPathComponent, size: data.count, modifiedAt: Date())
    }

    func data(for name: String) throws -> (file: RemoteSharedFile, data: Data, contentType: String) {
        try ensureDirectory()
        let safeName = Self.sanitizeFileName(name)
        guard safeName == name else { throw RemoteSharingError.invalidFileName }
        let url = directoryURL.appendingPathComponent(safeName, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == directoryURL.standardizedFileURL,
              fileManager.fileExists(atPath: url.path) else { throw RemoteSharingError.fileNotFound }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size <= RemoteSessionHost.maxRemoteFileBytes else { throw RemoteSharingError.invalidFile }
        let payload = try Data(contentsOf: url, options: [.mappedIfSafe])
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return (
            RemoteSharedFile(name: safeName, size: payload.count, modifiedAt: values.contentModificationDate ?? .distantPast),
            payload,
            type
        )
    }

    static func sanitizeFileName(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        let candidate = URL(fileURLWithPath: decoded).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._()-+@"))
        let filtered = candidate.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String((result.isEmpty ? "Shared file" : result).prefix(120))
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func uniqueDestination(for name: String) -> URL {
        let baseURL = URL(fileURLWithPath: name)
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        var candidate = directoryURL.appendingPathComponent(name, isDirectory: false)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            candidate = directoryURL.appendingPathComponent(next, isDirectory: false)
            suffix += 1
        }
        return candidate
    }
}

enum RemoteSharingError: LocalizedError {
    case invalidFileName
    case invalidFile
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidFileName: "That file name is not allowed."
        case .invalidFile: "Choose a non-empty file smaller than 20 MB."
        case .fileNotFound: "That shared file is no longer on the Mac."
        }
    }
}
