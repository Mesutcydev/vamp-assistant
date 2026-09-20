import Foundation

/// Keychain-backed storage for the TypeSafe API key — same contract as
/// `APIKeyStore`: cached in memory after the first read (each raw SecItem
/// access can prompt on ad-hoc signed builds), never in UserDefaults and
/// never in session files.
@MainActor
final class TypeSafeKeyStore: ObservableObject {

    static let shared = TypeSafeKeyStore()

    nonisolated private static let service = "com.beetcode.typesafe"
    nonisolated private static let account = "api-key"

    nonisolated private static let cacheLock = NSLock()
    // All access happens under cacheLock, which is what makes this safe.
    nonisolated(unsafe) private static var cachedKey: String?
    nonisolated(unsafe) private static var keyWasRead = false

    init() {}

    /// Thread-safe key read for background subsystems.
    nonisolated static func currentKey() -> String? {
        cacheLock.lock()
        if keyWasRead {
            let cached = cachedKey
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let value = Keychain.read(service: service, account: account)
        cacheLock.lock()
        cachedKey = value
        keyWasRead = true
        cacheLock.unlock()
        return value
    }

    nonisolated static func invalidateCache() {
        cacheLock.lock()
        cachedKey = nil
        keyWasRead = false
        cacheLock.unlock()
    }

    /// A client for the stored key, or nil when nothing is configured.
    nonisolated static func client(model: String) -> TypeSafeClient? {
        guard let key = currentKey() else { return nil }
        return TypeSafeClient(apiKey: key, model: model)
    }

    var hasKey: Bool { Self.currentKey() != nil }

    var key: String? { Self.currentKey() }

    func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.write(trimmed, service: Self.service, account: Self.account)
        Self.cacheLock.lock()
        Self.cachedKey = trimmed
        Self.keyWasRead = true
        Self.cacheLock.unlock()
        objectWillChange.send()
    }

    func delete() {
        Keychain.delete(service: Self.service, account: Self.account)
        Self.invalidateCache()
        objectWillChange.send()
    }

    /// Validates a draft WITHOUT persisting it, so an invalid key never lands
    /// in the Keychain. Returns the models the account can request.
    func validate(draft: String) async throws -> [String] {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TypeSafeError.missingKey }
        return try await TypeSafeClient(apiKey: trimmed).listModels()
    }

    /// Validates the stored key; returns the available model names.
    func validateStored() async throws -> [String] {
        guard let key = Self.currentKey() else { throw TypeSafeError.missingKey }
        return try await TypeSafeClient(apiKey: key).listModels()
    }
}
