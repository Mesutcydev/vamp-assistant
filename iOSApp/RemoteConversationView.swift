import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var store: RemoteStore
    let sessionID: UUID
    @Environment(\.remoteAppearance) private var appearance
    private var draft: String { store[draftFor: sessionID] }
    @State private var showSharing = false
    @State private var showComputers = false
    @State private var selectedModelID = ""
    @State private var dismissedErrorMessage: String?
    var body: some View {
        ZStack {
            RemoteBackdrop()
            if let detail = store.selectedSession, detail.id == sessionID {
                VStack(spacing: 0) {
                    ConversationStatus(
                        detail: detail,
                        models: store.startModels,
                        selectedModelID: $selectedModelID,
                        onStop: { Task { await store.stop() } },
                        onRefreshModels: { await store.loadStartModels() })
                    if !store.isConnected {
                        RemoteReconnectBanner(store: store)
                    }
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
            } else { ProgressView("Opening conversation…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.navigationTitle(store.sessions.first(where: { $0.id == sessionID })?.title ?? "Conversation").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showComputers = true } label: {
                        Image(systemName: "desktopcomputer.and.macbook")
                    }
                    .accessibilityLabel("Switch or add a Vamp Assistant computer")
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
                        Button { showSharing = true } label: {
                            Label("Share clipboard or files", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: store.fullAccess ? "lock.open.fill" : "ellipsis.circle")
                    }
                    .accessibilityLabel("Chat controls")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let detail = store.selectedSession, detail.id == sessionID {
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
                        RemoteComposer(
                            draft: $store[draftFor: sessionID],
                            isRunning: detail.isRunning,
                            isReachable: store.isConnected,
                            isSending: store.sendingSessionIDs.contains(sessionID),
                            onSend: { send() },
                            onQueue: { send(action: "queue") },
                            onSteer: { send(action: "steer") },
                            onStop: { Task { await store.stop() } })
                    }
                }
            }
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

struct ConversationStatus: View {
    let detail: RemoteSessionDetail
    let models: [RemoteStartModelOption]
    @Binding var selectedModelID: String
    var onStop: (() -> Void)? = nil
    var onRefreshModels: (() async -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    @State private var showPicker = false
    @State private var pickerSource = "local"

    private var selectedName: String {
        models.first(where: { $0.id == selectedModelID })?.name ?? detail.modelID
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(detail.isRunning ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)).frame(width: 7, height: 7)
            Text(detail.isRunning ? detail.phase.capitalized : "Ready").fontWeight(.semibold)
            Text("·")
            Text(detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty ? "Code" : "Chat")
                .fontWeight(.semibold)
            if detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty {
                Text("·")
                Text(detail.workspace).lineLimit(1)
            }
            Text("·")
            if models.isEmpty {
                Text(detail.modelID).lineLimit(1)
            } else {
                // A sheet, not a Menu: a Menu listing a few hundred gateway
                // models is unscrollable and unsearchable on a phone.
                Button {
                    pickerSource = models.first { $0.id == selectedModelID }?.source ?? "local"
                    showPicker = true
                } label: {
                    HStack(spacing: 3) {
                        Text(selectedName).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                }
                .buttonStyle(.plain)
                .disabled(detail.isRunning)
                .accessibilityLabel("Model, \(selectedName)")
                .accessibilityHint("Opens the searchable model list")
            }
            Spacer(minLength: 8)
            if detail.isRunning {
                Button(action: { onStop?() }) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background(BeetTheme.accent, in: Capsule())
                        .hitTarget(7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop the agent")
            } else {
                Label("\(detail.messages.count)", systemImage: "text.bubble")
            }
        }
        .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
        .padding(.horizontal, 16).frame(minHeight: 34)
        .background(BeetTheme.surface(appearance).opacity(0.62))
        .sheet(isPresented: $showPicker) {
            RemoteModelPickerSheet(
                models: models,
                source: $pickerSource,
                selectedModelID: $selectedModelID,
                onRefresh: onRefreshModels)
                .environment(\.remoteAppearance, appearance)
        }
    }
}
