import SwiftUI
import UIKit

/// The bots screen, rebuilt as a roster.
///
/// The old one was a settings form: a full-height hero, then the orchestrate
/// fields, and only then — below the fold — the bots themselves. You had to
/// scroll past a text field to find out who the bots were. This page puts the
/// five of them first, as portraits you can see at a glance, with whatever is
/// running pulled to the top and delegation at the bottom where you land after
/// reading the roster.
struct RemoteBotsView: View {
    let store: RemoteStore
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var path: [String] = []
    @State private var workflowPrompt = ""
    @State private var selectedModelID = ""

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intro
                    if !store.isConnected {
                        offlineCard
                    }
                    if !activeRuns.isEmpty {
                        section("Running now") {
                            VStack(spacing: 10) {
                                ForEach(activeRuns) { run in
                                    RemoteBotRunCard(run: run,
                                                     profile: RemoteBotProfile.profile(id: run.profileID)) {
                                        path.append(run.profileID)
                                    }
                                }
                            }
                        }
                    }
                    section("The team") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(RemoteBotProfile.profiles) { profile in
                                RemoteBotCard(profile: profile, run: run(for: profile.id)) {
                                    path.append(profile.id)
                                }
                            }
                        }
                    }
                    section("Delegate") { delegateCard }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
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

    private var intro: some View {
        Text("Five specialists on your Mac, each with its own brief. Open one to chat with it or set it running.")
            .font(.subheadline)
            .foregroundStyle(.primary.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.9)
                .foregroundStyle(.primary.opacity(0.55))
            content()
        }
    }

    private var offlineCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(BeetTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected").font(.subheadline.weight(.semibold))
                Text(store.connectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Connect") { Task { await store.connectSaved() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BeetTheme.accent)
        }
        .padding(14)
        .remoteCardSurface()
    }

    private var delegateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe an outcome and the bots divide the work between them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("What should the team get done?", text: $workflowPrompt, axis: .vertical)
                .font(.subheadline)
                .lineLimit(2...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RemoteSurface.well(appearance),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))

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
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary.opacity(0.75))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(RemoteSurface.well(appearance), in: Capsule())
                    }
                    .accessibilityLabel("Model for the workflow, \(modelName)")
                }
                Spacer(minLength: 0)
                Button {
                    let prompt = workflowPrompt
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task {
                        if await store.orchestrateBots(modelID: selectedModelID, prompt: prompt) {
                            workflowPrompt = ""
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                } label: {
                    Text("Delegate")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        // Drawn rather than `.borderedProminent`, which paints
                        // its own disabled fill and swallowed the accent.
                        .background(canOrchestrate ? AnyShapeStyle(BeetTheme.accent)
                                                   : AnyShapeStyle(RemoteSurface.well(appearance)),
                                    in: Capsule())
                        .foregroundStyle(canOrchestrate ? AnyShapeStyle(Color.white)
                                                        : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                }
                .buttonStyle(.plain)
                .disabled(!canOrchestrate)
                .accessibilityHint(store.isConnected ? "" : "Connect to your Mac first")
            }
        }
        .padding(14)
        .remoteCardSurface()
    }

    private var modelName: String {
        store.startModels.first { $0.id == selectedModelID }?.name ?? "Model"
    }

    private var activeRuns: [RemoteBotRun] {
        store.botRuns.filter { !$0.isTerminal }
    }

    private func run(for profileID: String) -> RemoteBotRun? {
        store.botRuns.first { $0.profileID == profileID && !$0.isTerminal }
            ?? store.botRuns.first { $0.profileID == profileID }
    }

    private var canOrchestrate: Bool {
        store.isConnected && !selectedModelID.isEmpty
            && !workflowPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One bot in the roster: the portrait first, because that is what makes these
/// read as five characters rather than five rows of settings.
private struct RemoteBotCard: View {
    let profile: RemoteBotProfile
    let run: RemoteBotRun?
    let action: () -> Void

    private var isActive: Bool { run.map { !$0.isTerminal } ?? false }

    private var statusText: String {
        guard let run else { return profile.isSpecialist ? "Idle" : "Chat only" }
        if run.isTerminal { return "Last run \(run.phase)" }
        return run.phase.capitalized
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                RemoteBotThumbnail(profile: profile, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(profile.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(isActive ? BeetTheme.accentBright : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(isActive ? BeetTheme.accentBright : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .buttonStyle(RemoteBotCardStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profile.name), \(profile.subtitle), \(statusText)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A run in flight, above the roster: what is working, on what, right now.
private struct RemoteBotRunCard: View {
    let run: RemoteBotRun
    let profile: RemoteBotProfile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                RemoteBotThumbnail(profile: profile, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(profile.name).font(.subheadline.weight(.semibold))
                        Text(run.phase.capitalized)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(BeetTheme.accentBright)
                        Spacer(minLength: 4)
                        if let queue = run.queuePosition {
                            Text("#\(queue)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    Text(run.prompt)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let gate = run.pendingInteraction ?? run.errorMessage {
                        Label(gate, systemImage: "exclamationmark.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(BeetTheme.accentBright)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .buttonStyle(RemoteBotCardStyle())
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteBotCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .remoteCardSurface(pressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
