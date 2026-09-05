import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One session.
///
/// The transcript used to be framed by three stacked chrome layers: a
/// navigation bar with two icon buttons, a status strip of seven inline items,
/// and the composer. The strip is gone — a two-line bar title carries phase,
/// folder and model, and Stop moved onto the run bar, where the run is.
struct ConversationView: View {
    @Bindable var store: RemoteStore
    let sessionID: UUID
    private var draft: String { store[draftFor: sessionID] }
    @State private var showSharing = false
    @State private var showComputers = false
    @State private var showModelPicker = false
    @State private var pickerSource = "local"
    @State private var selectedModelID = ""
    @State private var dismissedErrorMessage: String?

    private var detail: RemoteSessionDetail? {
        guard let detail = store.selectedSession, detail.id == sessionID else { return nil }
        return detail
    }

    private var title: String {
        store.sessions.first(where: { $0.id == sessionID })?.title ?? "Conversation"
    }

    /// Phase, where it works, and the model — the three things the status strip
    /// existed to say, in the space the navigation bar already reserves.
    private var subtitle: String {
        guard let detail else { return "Opening…" }
        var parts: [String] = [detail.isRunning ? detail.phase.capitalized : "Ready"]
        if detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty {
            parts.append(detail.workspace)
        } else {
            parts.append("Chat")
        }
        parts.append(selectedModelName)
        return parts.joined(separator: " · ")
    }

    private var selectedModelName: String {
        store.startModels.first(where: { $0.id == selectedModelID })?.name
            ?? detail?.modelID
            ?? ""
    }

    var body: some View {
        ZStack {
            RemoteBackdrop()
            if let detail {
                VStack(spacing: 0) {
                    if !store.isConnected { RemoteReconnectBanner(store: store) }
                    MessageTranscript(
                        detail: detail,
                        dismissedErrorMessage: dismissedErrorMessage,
                        onDismissError: { dismissedErrorMessage = detail.error?.message },
                        onRevertCheckpoint: detail.isRunning
                            ? nil
                            : { Task { await store.undoCheckpoint() } })
                    if let pending = detail.pending {
                        PendingInteractionView(
                            pending: pending,
                            isResolving: store.isResolvingPending(pending, sessionID: detail.id)) { value in
                                Task { await store.resolvePending(value) }
                            }
                            // Approval is a state transition, not a card
                            // insertion animation. Disabling the card while
                            // the POST and SSE acknowledgement settle keeps
                            // the transcript from jumping or flashing.
                            .transaction { transaction in transaction.animation = nil }
                    }
                }
            } else {
                ProgressView("Opening conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Auto mode", isOn: Binding(get: { store.autoMode }, set: { value in
                        Task { await store.setAccessMode(autoMode: value) }
                    })).disabled(store.isUpdatingAccess || !store.isConnected)
                    Toggle("Full Access", isOn: Binding(get: { store.fullAccess }, set: { value in
                        Task { await store.setAccessMode(fullAccess: value) }
                    })).disabled(store.isUpdatingAccess || !store.isConnected)
                    Divider()
                    Button("Model: \(selectedModelName)", systemImage: "cpu") {
                        pickerSource = store.startModels.first { $0.id == selectedModelID }?.source ?? "local"
                        showModelPicker = true
                    }
                    .disabled(detail?.isRunning == true || store.startModels.isEmpty)
                    Divider()
                    Button("Share clipboard or files", systemImage: "square.and.arrow.up") { showSharing = true }
                    Button("Switch computer", systemImage: "desktopcomputer.and.macbook") { showComputers = true }
                } label: {
                    Image(systemName: store.fullAccess ? "lock.open.fill" : "ellipsis.circle")
                }
                .accessibilityLabel("Chat controls")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .task(id: sessionID) {
            dismissedErrorMessage = nil
            await store.select(sessionID: sessionID)
            await store.loadStartModels()
            if selectedModelID.isEmpty {
                selectedModelID = store.startModels.matching(sessionModelID: store.selectedSession?.modelID ?? "")?.id ?? ""
            }
        }
        .onChange(of: selectedModelID) { old, new in
            guard !old.isEmpty, old != new else { return }
            dismissedErrorMessage = store.selectedSession?.error?.message ?? dismissedErrorMessage
        }
        .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
        .sheet(isPresented: $showComputers) { ComputerSwitcherSheet(store: store) }
        .sheet(isPresented: $showModelPicker) {
            RemoteModelPickerSheet(
                models: store.startModels,
                source: $pickerSource,
                selectedModelID: $selectedModelID,
                onRefresh: { await store.loadStartModels() })
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let detail {
            VStack(spacing: 8) {
                if let queued = detail.queued, !queued.isEmpty {
                    QueuedFollowUpsView(items: queued) { taskID in
                        Task { await store.cancelQueuedTask(taskID) }
                    }
                }
                if let warning = store.drafts.errorMessage {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16).accessibilityLabel(warning)
                }
                if detail.isRunning { runBar(detail) }
                RemoteComposer(
                    draft: $store[draftFor: sessionID],
                    isRunning: detail.isRunning,
                    isReachable: store.isConnected,
                    isSending: store.sendingSessionIDs.contains(sessionID),
                    onSend: { send() },
                    onQueue: { send(action: "queue") },
                    onSteer: { send(action: "steer") })
            }
        }
    }

    /// What the agent is doing right now, and the only control that matters
    /// while it does. Stop lived in the status strip and the composer both;
    /// this is the one place it exists.
    private func runBar(_ detail: RemoteSessionDetail) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(detail.phase.capitalized)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Stop") { Task { await store.stop() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Stop the agent")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground).opacity(0.9),
            in: Capsule())
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }

    private func send(action: String? = nil) {
        let message = draft
        let modelID = selectedModelID.isEmpty ? nil : selectedModelID
        Task {
            if await store.send(message, modelID: modelID, action: action, sessionID: sessionID) {
                if draft == message { store[draftFor: sessionID] = "" }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
