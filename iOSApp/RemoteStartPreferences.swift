import Foundation
import Observation

/// The choices the last started session was configured with.
///
/// Starting a session used to mean answering every question again — mode, bot,
/// model source, model, folder — on a form that reset itself each time it was
/// opened, and that picked the *first* model in a source even when a perfectly
/// good one had been used five minutes earlier. In practice almost every answer
/// repeats, so they are remembered here and the sheet opens on a configuration
/// that is already startable: type a prompt, hit Start.
@MainActor
@Observable
final class RemoteStartPreferences {
    static let shared = RemoteStartPreferences()

    /// Source order used when the remembered source has nothing in it. Local
    /// models need no account and no key, so they are the safest landing spot.
    static let sourceOrder = ["local", "chatgpt", "api"]

    private enum Key {
        static let botID = "remoteStartBotID"
        static let modelID = "remoteStartModelID"
        static let modelSource = "remoteStartModelSource"
        static let workspacePath = "remoteStartWorkspacePath"
    }

    private let defaults: UserDefaults

    var botID: String { didSet { defaults.set(botID, forKey: Key.botID) } }
    var modelID: String { didSet { defaults.set(modelID, forKey: Key.modelID) } }
    var modelSource: String { didSet { defaults.set(modelSource, forKey: Key.modelSource) } }
    /// Empty means the last session was chat-only. Folder-or-not *is* the
    /// mode now, so one remembered value carries both.
    var workspacePath: String { didSet { defaults.set(workspacePath, forKey: Key.workspacePath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        botID = defaults.string(forKey: Key.botID) ?? ""
        modelID = defaults.string(forKey: Key.modelID) ?? ""
        modelSource = defaults.string(forKey: Key.modelSource) ?? Self.sourceOrder[0]
        workspacePath = defaults.string(forKey: Key.workspacePath) ?? ""
    }

    func remember(model: RemoteStartModelOption) {
        modelID = model.id
        modelSource = model.source
    }

    /// The model the sheet should open on: the last used one if the Mac still
    /// offers it, otherwise anything in the last used source, otherwise the
    /// first model in the first source that has any.
    ///
    /// Falling through to another source matters more than it looks: remembering
    /// a source that is now empty is exactly what left the old sheet showing an
    /// empty list above a Start button that could never be tapped.
    static func resolveModel(
        in models: [RemoteStartModelOption],
        rememberedID: String,
        rememberedSource: String
    ) -> RemoteStartModelOption? {
        if let exact = models.first(where: { $0.id == rememberedID }) { return exact }
        if let sameSource = models.first(where: { $0.source == rememberedSource }) { return sameSource }
        for source in sourceOrder {
            if let fallback = models.first(where: { $0.source == source }) { return fallback }
        }
        return models.first
    }

    /// The folder the sheet should open on. An empty result means chat-only,
    /// which is a real answer here rather than a missing one.
    static func resolveWorkspacePath(
        in workspaces: [RemoteWorkspace],
        rememberedPath: String
    ) -> String {
        guard !rememberedPath.isEmpty else { return "" }
        if workspaces.contains(where: { $0.path == rememberedPath }) { return rememberedPath }
        return workspaces.first(where: { $0.isCurrent == true })?.path
            ?? workspaces.first?.path
            ?? ""
    }
}
