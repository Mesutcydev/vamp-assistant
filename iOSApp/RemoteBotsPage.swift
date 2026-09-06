import SwiftUI
import UIKit

/// The bots screen: five names, what each one does, and what it is doing now.
///
/// It was a grid of portrait cards, and before that a settings form. The
/// portraits were the problem — five desaturated engravings read as five
/// identical grey discs at row size, so the cards carried weight without
/// carrying information. This is hairline rows on the ground with one line
/// glyph each: name, brief, one status word. Work in flight is a live row at
/// the top with the only Stop, and delegating to the whole team is the last
/// row rather than a form you scroll past.
struct RemoteBotsView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var path: [String] = []
    @State private var selectedModelID = ""
    @State private var showDelegate = false
    @State private var stopping: Set<UUID> = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !store.isConnected { offlineRow }

                    if !activeRuns.isEmpty {
                        heading("Running")
                        hairline
                        ForEach(activeRuns) { run in
                            RemoteBotRunRow(
                                run: run,
                                profile: RemoteBotProfile.profile(id: run.profileID),
                                isStopping: stopping.contains(run.id),
                                onOpen: { path.append(run.profileID) },
                                onStop: { stop(run) })
                            hairline
                        }
                    }

                    heading("Team")
                    hairline
                    ForEach(RemoteBotProfile.profiles) { profile in
                        RemoteBotRow(profile: profile, run: run(for: profile.id)) {
                            path.append(profile.id)
                        }
                        hairline
                    }

                    heading("Together")
                    hairline
                    RemoteBotPlainRow(
                        symbol: "person.3.sequence",
                        title: "Delegate one outcome",
                        detail: "They divide the work between them",
                        showsChevron: true) { showDelegate = true }
                    hairline
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .remoteContentSheet()
            .background { RemoteBackdrop() }
            .refreshable { try? await store.refresh() }
            .navigationTitle("Bots")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { id in
                RemoteBotDetailView(
                    store: store,
                    profile: RemoteBotProfile.profile(id: id),
                    selectedModelID: $selectedModelID,
                    onOpen: onOpen)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showDelegate) {
                RemoteDelegateSheet(store: store, selectedModelID: $selectedModelID)
                    .environment(\.remoteAppearance, appearance)
            }
            .keyboardDismissToolbar()
            .task {
                if store.startModels.isEmpty { await store.loadStartModels() }
                if selectedModelID.isEmpty { selectedModelID = store.startModels.first?.id ?? "" }
                try? await store.refresh()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .remoteSectionHeadingStyle()
            .padding(.top, 26)
            .padding(.bottom, 6)
    }

    private var hairline: some View {
        Rectangle()
            .fill(RemoteSurface.separator(appearance))
            .frame(height: 0.75)
    }

    private var offlineRow: some View {
        RemoteBotPlainRow(
            symbol: "wifi.exclamationmark",
            title: "Not connected",
            detail: store.connectionSubtitle,
            trailing: store.isConnecting ? "Connecting…" : "Reconnect") {
                Task { await store.connectSaved() }
            }
    }

    private var activeRuns: [RemoteBotRun] {
        store.botRuns.filter { !$0.isTerminal }
    }

    private func run(for profileID: String) -> RemoteBotRun? {
        store.botRuns.first { $0.profileID == profileID && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == profileID }
    }

    private func stop(_ run: RemoteBotRun) {
        guard !stopping.contains(run.id) else { return }
        stopping.insert(run.id)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        Task {
            _ = await store.stopBotRun(run.id)
            try? await store.refresh()
            stopping.remove(run.id)
        }
    }
}

/// A run in flight — the live one, not a mock: the phase the Mac reports, the
/// time since it started ticking every second, and the Stop that ends it.
private struct RemoteBotRunRow: View {
    let run: RemoteBotRun
    let profile: RemoteBotProfile
    let isStopping: Bool
    let onOpen: () -> Void
    let onStop: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    Image(systemName: profile.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(BeetTheme.accentBright)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).font(.headline)
                        // Live: the phase comes off the run, the clock off a
                        // timeline that reticks every second.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(statusLine)
                                .font(.footnote)
                                .foregroundStyle(BeetTheme.accentBright)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onStop) {
                Text(isStopping ? "Stopping…" : "Stop")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary.opacity(isStopping ? 0.4 : 0.85))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 5)
                    .background(RemoteSurface.well(appearance), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isStopping)
            .accessibilityLabel("Stop \(profile.name)")
        }
        .frame(minHeight: 58)
        .accessibilityElement(children: .contain)
    }

    private var statusLine: String {
        var parts = [run.phase.capitalized]
        if let queue = run.queuePosition { parts.append("queue #\(queue)") }
        parts.append(elapsed)
        if let gate = run.pendingInteraction, !gate.isEmpty { parts.append(gate) }
        return parts.joined(separator: " · ")
    }

    private var elapsed: String {
        let seconds = max(0, Int(Date().timeIntervalSince1970 - run.createdAt))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// One bot: glyph, name, brief, and the one word for what it is doing.
private struct RemoteBotRow: View {
    let profile: RemoteBotProfile
    let run: RemoteBotRun?
    let action: () -> Void

    private var isActive: Bool { run.map { !$0.isTerminal } ?? false }

    private var statusText: String {
        guard let run else { return profile.isSpecialist ? "Idle" : "Chat only" }
        if run.isTerminal { return run.phase.capitalized }
        return run.phase.capitalized
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: profile.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isActive ? AnyShapeStyle(BeetTheme.accentBright)
                                              : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.headline).foregroundStyle(.primary)
                    Text(profile.subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(isActive ? AnyShapeStyle(BeetTheme.accentBright)
                                              : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(RemoteInk.quiet)
            }
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(profile.subtitle), \(statusText)")
    }
}

/// The same row shape for the things that are not bots: offline, delegate.
private struct RemoteBotPlainRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var trailing: String?
    var showsChevron = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    if let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BeetTheme.accent)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(RemoteInk.quiet)
                }
            }
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Delegating to the whole team: one outcome, one model, one button. A sheet
/// rather than a block on the roster, because it is a task, not a status.
private struct RemoteDelegateSheet: View {
    let store: RemoteStore
    @Binding var selectedModelID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var prompt = ""
    @State private var isSending = false
    @FocusState private var focused: Bool

    private var canSend: Bool {
        store.isConnected && !selectedModelID.isEmpty && !isSending
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Describe an outcome. The bots divide the work between them.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("What should the team get done?", text: $prompt, axis: .vertical)
                    .font(.body)
                    .lineLimit(3...8)
                    .focused($focused)
                    .padding(12)
                    .background(RemoteSurface.well(appearance),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 10) {
                    if !store.startModels.isEmpty {
                        Menu {
                            Picker("Model", selection: $selectedModelID) {
                                ForEach(store.startModels) { Text($0.name).tag($0.id) }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "cpu")
                                Text(modelName)
                                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary.opacity(0.75))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(RemoteSurface.well(appearance), in: Capsule())
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        send()
                    } label: {
                        Text(isSending ? "Starting…" : "Delegate")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 9)
                            .background(canSend ? AnyShapeStyle(BeetTheme.accent)
                                                : AnyShapeStyle(RemoteSurface.well(appearance)),
                                        in: Capsule())
                            .foregroundStyle(canSend ? AnyShapeStyle(Color.white)
                                                     : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background { RemoteBackdrop() }
            .navigationTitle("Delegate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .keyboardDismissToolbar()
            .task { focused = true }
        }
        .presentationDetents([.medium])
    }

    private var modelName: String {
        store.startModels.first { $0.id == selectedModelID }?.name ?? "Model"
    }

    private func send() {
        let text = prompt
        isSending = true
        Task {
            if await store.orchestrateBots(modelID: selectedModelID, prompt: text) {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                try? await store.refresh()
                dismiss()
            }
            isSending = false
        }
    }
}
