import Foundation
import SwiftUI

// MARK: - Design preview fixture
//
// A deterministic, inert conversation used ONLY for visual verification of
// the reference design (`--design-preview <screen>` launch argument). It
// installs fixture rows into the REAL transcript/plan/approval views so the
// captured screens exercise production rendering paths.
//
// Safety: nothing here persists, executes tools, grants permissions, or
// touches the network. A preview approval resolves exactly like the real
// card's UI state change (the pending request clears); no executor runs.

enum DesignPreviewScreen: String, CaseIterable {
    case chat
    case composer
    case welcome
    case settingsGeneral = "settings-general"
    case settingsModels = "settings-models"
    case settingsBots = "settings-bots"
    case settingsAgent = "settings-agent"
    case settingsNetwork = "settings-network"
    case settingsPlugins = "settings-plugins"
    case settingsHover = "settings-hover"
    case settingsFocus = "settings-focus"
    case botsDashboard = "bots"

    static func fromLaunchArguments() -> DesignPreviewScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--design-preview") else { return nil }
        let value = args.indices.contains(index + 1) ? args[index + 1] : "chat"
        return DesignPreviewScreen(rawValue: value) ?? .chat
    }
}

enum DesignPreview {
    /// Dev-only appearance override for captures (`--design-appearance
    /// light|dark`). Never set in production launches; user preferences are
    /// never written.
    static let appearanceOverride: AppAppearance? = {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--design-preview"),
              let index = args.firstIndex(of: "--design-appearance"),
              args.indices.contains(index + 1) else { return nil }
        return AppAppearance(rawValue: args[index + 1])
    }()

    @MainActor
    static func install(_ screen: DesignPreviewScreen,
                        into sessions: AgentSessionController) {
        switch screen {
        case .chat:
            sessions.installDesignPreview(
                transcript: transcript,
                plan: plan,
                approval: approval)
        case .composer:
            // Canonical composer fixture: short valid draft, no network,
            // no permission or history mutation. Model selection is left to
            // the real app state; the fixture only seeds the draft.
            sessions.installDesignPreview(
                transcript: [],
                plan: [],
                approval: approval)
        case .welcome, .settingsGeneral, .settingsModels, .settingsBots,
             .settingsAgent, .settingsNetwork, .settingsPlugins,
             .settingsHover, .settingsFocus, .botsDashboard:
            break
        }
    }

    // MARK: Fixture content (sample copy from the reference artboard)

    private static var transcript: [AgentSessionController.TranscriptItem] {
        let searchID = UUID()
        let readID = UUID()
        let editID = UUID()
        return [
            .init(id: UUID(), kind: .user(
                "The keyboard chip overlaps the send button on iOS. Fix it everywhere it happens.")),
            .init(id: UUID(), kind: .assistant(
                "The accessory was attached to the sessions **NavigationStack**, so it followed the push into the conversation and drew a second trailing button under the composer. Three screens have that shape.")),
            .init(id: UUID(), kind: .toolCall(ToolInvocation(
                id: searchID, name: "search", argumentsJSON: "{}",
                summary: "keyboardDismissToolbar — 8 matches"))),
            .init(id: UUID(), kind: .toolResult(
                id: searchID, output: "8 matches", failed: false, toolName: "search")),
            .init(id: UUID(), kind: .toolCall(ToolInvocation(
                id: readID, name: "read_file", argumentsJSON: "{}",
                summary: "RemoteSessionViews.swift, RemoteBotsPage.swift"))),
            .init(id: UUID(), kind: .toolResult(
                id: readID, output: "read", failed: false, toolName: "read_file")),
            .init(id: UUID(), kind: .toolCall(ToolInvocation(
                id: editID, name: "write_file", argumentsJSON: "{}",
                summary: "3 files · +7 −4"))),
            .init(id: UUID(), kind: .toolResult(
                id: editID, output: "applied", failed: false, toolName: "write_file")),
        ]
    }

    private static var plan: [AgentSessionController.PlanEntry] {
        [
            .init(step: "Find every call site", status: "completed"),
            .init(step: "Separate the ones with their own bottom action", status: "completed"),
            .init(step: "Swap those for interactive scroll dismissal", status: "pending"),
            .init(step: "Build and verify on device", status: "pending"),
        ]
    }

    private static var approval: ApprovalRequest {
        let diff = DiffEngine.Result(
            lines: [
                .init(kind: .added, text: ".toolbar(removing: .keyboard)"),
                .init(kind: .removed, text: ".keyboardDismissToolbar()"),
            ],
            addedCount: 1,
            removedCount: 1)
        return ApprovalRequest(
            id: UUID(),
            invocation: ToolInvocation(
                name: "write_file",
                argumentsJSON: "{}",
                summary: "Edit RemoteComposerView.swift"),
            preview: .diff(diff, path: "RemoteComposerView.swift"))
    }
}
