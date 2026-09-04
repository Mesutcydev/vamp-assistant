import Foundation
import Observation

private actor RemoteDraftDisk {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("drafts.json"), options: [.atomic, .completeFileProtection])
    }
}

@MainActor
@Observable
final class RemoteDraftStore {
    private struct Entry: Codable {
        var text: String
        var updatedAt: Date
    }
    private var entries: [String: Entry] = [:]
    private let disk: RemoteDraftDisk?
    private var pendingSave: Task<Void, Never>?
    private var revision: UInt64 = 0
    private(set) var errorMessage: String?

    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VampDrafts", isDirectory: true)) {
        disk = directory.map(RemoteDraftDisk.init(directory:))
        guard let directory else { return }
        let file = directory.appendingPathComponent("drafts.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
        } catch {
            errorMessage = "Saved drafts could not be restored. Existing drafts on disk have not been removed."
        }
    }

    subscript(computerID: UUID, sessionID: UUID) -> String {
        get { entries[Self.key(computerID, sessionID)]?.text ?? "" }
        set {
            let key = Self.key(computerID, sessionID)
            if newValue.isEmpty { entries.removeValue(forKey: key) }
            else { entries[key] = Entry(text: newValue, updatedAt: Date()) }
            revision &+= 1
            pendingSave?.cancel()
            pendingSave = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                await self?.persist()
            }
        }
    }

    func flush() async {
        pendingSave?.cancel()
        pendingSave = nil
        await persist()
    }

    func remove(computerID: UUID) {
        entries = entries.filter { !$0.key.hasPrefix(computerID.uuidString + "/") }
        revision &+= 1
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in await self?.persist() }
    }

    private func persist() async {
        guard let disk else { return }
        let savedRevision = revision
        do {
            let data = try JSONEncoder().encode(entries)
            guard data.count <= 2 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
            try await disk.save(data)
            if savedRevision == revision { errorMessage = nil }
        } catch {
            if savedRevision == revision {
                errorMessage = "Your draft is still here, but could not be saved on this device. Keep the app open and try again."
            }
        }
    }

    private static func key(_ computerID: UUID, _ sessionID: UUID) -> String {
        computerID.uuidString + "/" + sessionID.uuidString
    }
}
