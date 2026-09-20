import AppKit
import SwiftUI

// MARK: - Detached conversation window
//
// A conversation separated into its own window from the sidebar row's
// "Open in New Window". It gets its own session controller and composer store,
// so its draft and streaming stay attached to that conversation.

/// Commands the workspace key forwards to the window.
enum WorkspaceCommand {
    case newChat
    case openProject
    case chatOnly
    case importChats
    case importBundle
    case refresh
}

struct DetachedChatWindow: View {
    let sessionID: UUID
    @EnvironmentObject private var appState: AppState
    @State private var controller: AgentSessionController?
    @State private var store = ComposerStore()
    @State private var title = "Chat"

    var body: some View {
        Group {
            if let controller {
                ChatView(controller: controller, store: store)
                    .environmentObject(appState)
                    .environmentObject(controller)
            } else {
                Theme.workspaceCanvas
            }
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Theme.workspaceCanvas)
        .navigationTitle(title)
        .task {
            guard controller == nil else { return }
            let created = AgentSessionController(
                engine: appState.engine,
                settings: SettingsStore.shared,
                thermal: appState.thermal,
                codexAccount: appState.codexAccount)
            // Same budgets and catalogs as the main window's controller.
            created.maxTokensHandler = appState.sessions.maxTokensHandler
            created.openCodeCatalogHandler = appState.sessions.openCodeCatalogHandler
            controller = created
            let record = await Task.detached(priority: .userInitiated) {
                SessionStore.shared.load(id: sessionID)
            }.value
            if let record {
                _ = created.restore(record)
                title = SessionTitle.display(for: record)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionTitleChanged)) { note in
            guard let id = note.object as? UUID, id == sessionID,
                  let newTitle = note.userInfo?["title"] as? String else { return }
            title = newTitle
        }
    }
}
