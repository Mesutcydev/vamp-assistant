import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConversationView: View {
    @Bindable var store: RemoteStore
    let sessionID: UUID
    @Environment(\.remoteAppearance) private var appearance
    private var draft: String { store[draftFor: sessionID] }
    @State private var showModelPicker = false
    @State private var pickerSource = "local"
    @State private var showSharing = false
    @State private var selectedModelID = ""
    @State private var dismissedErrorMessage: String?

    /// Chat titles arrive as generated Markdown. The navigation bar displays
    /// plain text, so emphasis and code delimiters must be removed before
    /// SwiftUI truncates the title.
    private var displayTitle: String {
        let raw = store.sessions.first(where: { $0.id == sessionID })?.title ?? "Conversation"
        var title = raw
        let emphasisPatterns = [
            #"\*\*([^*\n]+)\*\*"#,
            #"\*([^*\n]+)\*"#,
            #"__([^_\n]+)__"#,
            #"_([^_\n]+)_"#,
            #"`([^`\n]+)`"#,
        ]
        for pattern in emphasisPatterns {
            title = title.replacingOccurrences(
                of: pattern, with: "$1", options: .regularExpression)
        }
        title = title
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return title.isEmpty ? "Conversation" : title
    }

    var body: some View {
        ZStack {
            RemoteBackdrop()
            if let detail = store.selectedSession, detail.id == sessionID {
                VStack(spacing: 0) {
                    ConversationStatus(
                        detail: detail,
                        models: store.startModels,
                        selectedModelID: $selectedModelID,
                        showsModel: false,
                        isReachable: store.isConnected,
                        isSending: store.sendingSessionIDs.contains(sessionID),
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
            } else {
                ConversationOpeningState(
                    message: store.selectedSessionError ?? store.errorMessage,
                    retry: {
                        await store.select(sessionID: sessionID)
                        await store.loadStartModels()
                    })
            }
        }.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .remoteNavigationChrome()
            .keyboardDismissToolbar()
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.92), for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 170)
                        .padding(.horizontal, 4)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    let locked = store.isUpdatingAccess || !store.isConnected
                    InstrumentKeyBank(
                        selection: Binding(
                            get: { store.isFullAccessSelected },
                            set: { full in
                                Task { await store.setAccessMode(autoMode: !full, fullAccess: full) }
                            }),
                        titles: ["AUTO", "FULL"],
                        values: [false, true],
                        isMono: true,
                        size: .compact)
                    .disabled(locked)
                    .accessibilityLabel("Access mode")
                }
                .vampUtilityAction()
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
                            Text(warning).font(.caption).foregroundStyle(RemoteInstrument.orange)
                                .padding(.horizontal, 16).accessibilityLabel(warning)
                        }
                        RemoteComposer(
                            draft: $store[draftFor: sessionID],
                            isRunning: detail.isRunning,
                            isReachable: store.isConnected,
                            isSending: store.sendingSessionIDs.contains(sessionID),
                            hasError: detail.error != nil,
                            onSend: { send() },
                            onQueue: { send(action: "queue") },
                            onSteer: { send(action: "steer") },
                            onStop: { Task { await store.stop() } },
                            modelName: store.startModels.first(where: { $0.id == selectedModelID })?.name ?? detail.modelID,
                            onSelectModel: {
                                pickerSource = store.startModels.first { $0.id == selectedModelID }?.source ?? "local"
                                showModelPicker = true
                            },
                            onShare: { showSharing = true },
                            modeName: detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty ? "Code" : "Chat")
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
            .sheet(isPresented: $showModelPicker) {
                RemoteModelPickerSheet(models: store.startModels,
                    modeName: store.selectedSession?.mode == "code" || !(store.selectedSession?.workspacePath ?? "").isEmpty ? "Code" : "Chat",
                    source: $pickerSource,
                    selectedModelID: $selectedModelID, onRefresh: { await store.loadStartModels() })
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showSharing) { RemoteShareSheet(store: store) }
    }
    private func send(action: String? = nil) {
        let message = draft
        let modelID = selectedModelID.isEmpty ? nil : selectedModelID
        Task {
            if await store.send(message, modelID: modelID, action: action, sessionID: sessionID) {
                if store[draftFor: sessionID] == message { store[draftFor: sessionID] = "" }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

struct ConversationOpeningState: View {
    let message: String?
    let retry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 12) {
            if message == nil {
                ProgressView()
                Text("Opening conversation…")
                    .foregroundStyle(RemoteInstrument.secondaryInk)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(RemoteInstrument.orange)
                Text("Couldn’t open this conversation")
                    .font(.headline)
                Text(message ?? "Try again.")
                    .font(.subheadline)
                    .foregroundStyle(RemoteInstrument.secondaryInk)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button {
                    isRetrying = true
                    Task { @MainActor in
                        defer { isRetrying = false }
                        await retry()
                    }
                } label: {
                    if isRetrying { ProgressView() }
                    else { Text("Retry") }
                }
                .buttonStyle(RemotePrimaryButtonStyle())
                .disabled(isRetrying)
            }
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationStatus: View {
    let detail: RemoteSessionDetail
    let models: [RemoteStartModelOption]
    @Binding var selectedModelID: String
    var showsModel = true
    var isReachable = true
    var isSending = false
    var onStop: (() -> Void)? = nil
    var onRefreshModels: (() async -> Void)? = nil
    @Environment(\.remoteAppearance) private var appearance
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showPicker = false
    @State private var pickerSource = "local"

    private var selectedName: String {
        models.first(where: { $0.id == selectedModelID })?.name ?? detail.modelID
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            detailedStatus
            compactStatus
        }
        .font(.caption2.monospaced())
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(BeetTheme.secondaryText(appearance))
        .padding(.horizontal, 12)
        .padding(.vertical, verticalSizeClass == .compact ? 3 : 6)
        .frame(maxWidth: .infinity, minHeight: verticalSizeClass == .compact ? 26 : 34, alignment: .leading)
        .background(BeetTheme.readingSurface(appearance))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BeetTheme.line(appearance))
                .frame(height: 0.75)
        }
        .sheet(isPresented: $showPicker) {
            RemoteModelPickerSheet(
                models: models,
                source: $pickerSource,
                selectedModelID: $selectedModelID,
                onRefresh: onRefreshModels)
                .environment(\.remoteAppearance, appearance)
        }
    }

    private var detailedStatus: some View {
        HStack(spacing: 7) {
            statusIdentity
            Spacer(minLength: 8)
            if showsModel { modelControl }
            statusAction
        }
    }

    private var compactStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                statusIdentity
                Spacer(minLength: 8)
                statusAction
            }
            if showsModel { HStack(spacing: 7) {
                Text(detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty ? "Code" : "Chat")
                    .fontWeight(.semibold)
                if detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty {
                    Text("·")
                    Text(detail.workspace).lineLimit(1)
                }
                Text("·")
                modelControl
            } }
        }
    }

    private var statusIdentity: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(!isReachable ? RemoteInstrument.secondaryInk : (detail.error != nil ? RemoteInstrument.danger : (detail.isRunning || isSending ? RemoteInstrument.orange : RemoteInstrument.green)))
                .frame(width: 5.5, height: 5.5)
            Text((!isReachable ? "Offline" : detail.error != nil ? "Error" : isSending ? "Sending" : detail.isRunning ? detail.phase.capitalized : "Ready").uppercased())
                .fontWeight(.semibold)
            Text("·")
            Text(detail.mode == "code" || !(detail.workspacePath ?? "").isEmpty ? "Code" : "Chat")
                .textCase(.uppercase)
                .fontWeight(.semibold)
        }
    }

    private var modelControl: some View {
        Group {
            if models.isEmpty {
                Text(detail.modelID).lineLimit(1)
            } else {
                Button {
                    pickerSource = models.first { $0.id == selectedModelID }?.source ?? "local"
                    showPicker = true
                } label: {
                    HStack(spacing: 3) {
                        Text(selectedName).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .disabled(detail.isRunning)
                .accessibilityLabel("Model, \(selectedName)")
                .accessibilityHint("Opens the searchable model list")
            }
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        if detail.isRunning {
            Button(action: { onStop?() }) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)

            }
            .buttonStyle(RemoteKeyButtonStyle(prominent: true))
            .disabled(!isReachable || isSending)
            .accessibilityLabel("Stop the agent")
        } else {
            Label("\(detail.messages.count)", systemImage: "text.bubble")
        }
    }
}
