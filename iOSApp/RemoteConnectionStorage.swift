import Foundation

/// Separates connection metadata and Keychain access from asynchronous UI
/// state. Tests can provide isolated storage without touching saved Macs.
@MainActor
protocol RemoteConnectionPersisting {
    func load() -> (computers: [PairedBeetCodeComputer], activeID: UUID?)
    func save(computers: [PairedBeetCodeComputer], activeID: UUID?)
    func token(for computerID: UUID) -> String?
    func saveToken(_ token: String, for computerID: UUID) throws
    func clearToken(for computerID: UUID)
}

@MainActor
struct RemoteConnectionStorage: RemoteConnectionPersisting {
    var defaults: UserDefaults = .standard

    func load() -> (computers: [PairedBeetCodeComputer], activeID: UUID?) {
        if let data = defaults.data(forKey: "pairedBeetCodeComputers"),
           let computers = try? JSONDecoder().decode([PairedBeetCodeComputer].self, from: data),
           !computers.isEmpty {
            return (computers, defaults.string(forKey: "activeBeetCodeComputerID").flatMap(UUID.init(uuidString:)))
        }
        if let address = defaults.string(forKey: "remoteBaseURL"),
           let url = URL(string: address), let legacyToken = RemoteTokenStore.loadLegacy() {
            let computer = PairedBeetCodeComputer(baseURL: url)
            // Retain the legacy credential if Keychain is temporarily locked.
            // A failed migration must never delete the only saved token.
            do { try saveToken(legacyToken, for: computer.id) }
            catch { return ([], nil) }
            save(computers: [computer], activeID: computer.id)
            RemoteTokenStore.clearLegacy()
            defaults.removeObject(forKey: "remoteBaseURL")
            return ([computer], computer.id)
        }
        return ([], nil)
    }

    func save(computers: [PairedBeetCodeComputer], activeID: UUID?) {
        if let data = try? JSONEncoder().encode(computers) {
            defaults.set(data, forKey: "pairedBeetCodeComputers")
        }
        defaults.set(activeID?.uuidString, forKey: "activeBeetCodeComputerID")
    }

    func token(for computerID: UUID) -> String? { RemoteTokenStore.load(computerID: computerID) }
    func saveToken(_ token: String, for computerID: UUID) throws {
        try RemoteTokenStore.save(token, computerID: computerID)
    }
    func clearToken(for computerID: UUID) { RemoteTokenStore.clear(computerID: computerID) }
}
