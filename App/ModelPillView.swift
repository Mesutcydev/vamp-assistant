import SwiftUI

// MARK: - Composer model pill
//
// The composer's single source of model truth. Shows WHICH engine will run
// the next message — a loaded local model, an active BYOK provider, or a
// "Choose Model" affordance — and opens a designed popover that can switch
// it without leaving the composer. Every label derives from AppState; the
// pill never holds its own model string.

struct ModelSelectionPill: View {
    @EnvironmentObject private var appState: AppState
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 6) {
                // A status dot before the icon: engine health is glanceable
                // even when the icon itself only says local vs remote.
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            // Model identity is a text control in the command line, not a
            // competing badge. The status dot carries readiness at a glance.
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(minHeight: 26)
            .background(showPopover ? Theme.washStrong(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottom) {
                if case .ready = appState.enginePhase {
                    Capsule()
                        .fill(borderColor)
                        .frame(width: 20, height: 2)
                }
            }
            .lfHoverLift()
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("Active model: \(label)")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            ModelPickerPopover()
                .environmentObject(appState)
                .frame(width: 340)
        }
    }

    // MARK: Derived state — one canonical source (AppState/engine)

    private var label: String {
        switch appState.enginePhase {
        case .ready(let name):
            return name
        case .loading(let name):
            return "Loading \(name)…"
        case .failed:
            return "Choose Model"
        case .idle:
            return appState.activeModel != nil
                ? appState.activeModel!.displayName
                : "Choose Model"
        }
    }

    private var icon: String {
        if case .loading = appState.enginePhase { return "hourglass" }
        if case .failed = appState.enginePhase { return "exclamationmark.triangle" }
        if appState.isCodexActive { return "person.crop.circle.fill" }
        return appState.isRemoteActive ? "cloud.fill" : "cpu.fill"
    }

    private var iconColor: Color {
        switch appState.enginePhase {
        case .ready: return Theme.success
        case .loading: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textSecondary
        }
    }

    private var statusColor: Color {
        switch appState.enginePhase {
        case .ready: return Theme.success
        case .loading: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textTertiary
        }
    }

    private var borderColor: Color {
        if showPopover { return Theme.washBorder(Theme.accent) }
        if case .ready = appState.enginePhase { return Theme.washBorder(Theme.accent) }
        return Theme.hairline
    }

    private var tooltip: String {
        switch appState.enginePhase {
        case .ready(let name): return "Active model: \(name). Click to switch."
        case .loading(let name): return "Loading \(name)…"
        case .failed: return "No usable model. Click to pick one."
        case .idle: return "No model loaded. Click to pick one."
        }
    }
}

// MARK: - Picker popover

/// Designed popup: installed local models first (Load / active), then
/// configured BYOK providers, then management entries. Selecting anything
/// here performs the real switch — no decorative rows.
private struct ModelPickerPopover: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyStore = APIKeyStore.shared
    @ObservedObject private var codexAccount = CodexAccountStore.shared
    private enum Source: String, CaseIterable, Identifiable {
        case local, api, account
        var id: String { rawValue }
        var label: String {
            switch self {
            case .local: "Local models"
            case .api: "API models"
            case .account: "OpenAI account"
            }
        }
    }
    @State private var source: Source = .local
    @State private var reasoningEffort: String?

    private var installedModels: [CatalogModel] {
        // Chat models only — vision sidecars are never loadable here; the
        // app runs them automatically for image attachments.
        ModelCatalog.all.filter {
            $0.role == .chat && appState.modelStore.isInstalled(catalogModel: $0)
        }
    }

    private var remoteProviders: [LLMProvider] {
        APIKeyStore.shared.configuredProviders.sorted { $0.displayName < $1.displayName }
    }

    private var remoteModels: [RemoteModelProfile] {
        RemoteAPIModelCatalog.profiles(
            configuredProviders: Set(remoteProviders),
            selectedModelByProvider: AppPreferencesStore.shared.current.remoteModel,
            savedProfiles: Array(AppPreferencesStore.shared.current.remoteModelProfiles.values),
            hasKeyForProviderID: { keyStore.hasKey(forProviderID: $0) },
            openCodeProfiles: appState.openCodeCatalog.models.map { $0.remoteProfile() }
        )
        .map { $0.applying(AppPreferencesStore.shared.remoteModelOverride(endpoint: $0.endpoint())) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model source", selection: $source) {
                        ForEach(Source.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.bottom, 2)
                    activeReasoningControl
                    if source == .local {
                        localSection
                    } else if source == .api {
                        apiSection
                    } else {
                        accountSection
                    }
                }
                .padding(12)
            }
            Divider()
            footer
        }
        // Opaque themed surface — a material popover would stay neutral
        // gray in Beet mode while everything around it goes plum.
        .background(Theme.surface)
        .task {
            await codexAccount.refresh()
            if appState.isCodexActive {
                source = .account
            } else if appState.isRemoteActive {
                source = .api
            } else {
                source = .local
            }
            loadReasoningEffort()
        }
        .onChange(of: source) { _, _ in loadReasoningEffort() }
        .onChange(of: appState.activeCodexModelID) { _, _ in loadReasoningEffort() }
        .onChange(of: appState.engine.activeRemoteEndpoint) { _, _ in loadReasoningEffort() }
    }

    @ViewBuilder
    private var activeReasoningControl: some View {
        if source == .api, let profile = activeRemoteReasoningProfile,
           !profile.effectiveReasoningEfforts.isEmpty {
            ReasoningModelControl(
                modelName: profile.displayName ?? profile.model,
                options: profile.effectiveReasoningEfforts.map(\.rawValue),
                defaultEffort: profile.effectiveDefaultReasoningEffort,
                selection: $reasoningEffort,
                onSelect: { saveRemoteReasoningEffort($0, profile: profile) })
        } else if source == .account, let model = activeCodexReasoningModel,
                  !model.supportedReasoningEfforts.isEmpty {
            ReasoningModelControl(
                modelName: model.displayName,
                options: model.supportedReasoningEfforts,
                defaultEffort: model.defaultReasoningEffort,
                selection: $reasoningEffort,
                onSelect: { effort in
                    AppPreferencesStore.shared.saveCodexReasoningEffort(effort, modelID: model.id)
                })
        }
    }

    private var activeRemoteReasoningProfile: RemoteModelProfile? {
        guard appState.isRemoteActive, let endpoint = appState.engine.activeRemoteEndpoint else { return nil }
        let base = remoteModels.first { $0.endpoint() == endpoint }
            ?? AppPreferencesStore.shared.remoteModelProfile(endpoint: endpoint)
        return base?.applying(AppPreferencesStore.shared.remoteModelOverride(endpoint: endpoint))
    }

    private var activeCodexReasoningModel: CodexModelProfile? {
        guard appState.isCodexActive, let id = appState.activeCodexModelID else { return nil }
        return codexAccount.models.first { $0.id == id }
    }

    private func loadReasoningEffort() {
        if source == .api, let profile = activeRemoteReasoningProfile {
            reasoningEffort = AppPreferencesStore.shared
                .remoteModelOverride(endpoint: profile.endpoint())?.reasoningEffort
        } else if source == .account, let model = activeCodexReasoningModel {
            reasoningEffort = AppPreferencesStore.shared.codexReasoningEffort(modelID: model.id)
        } else {
            reasoningEffort = nil
        }
    }

    private func saveRemoteReasoningEffort(_ effort: String?, profile: RemoteModelProfile) {
        let endpoint = profile.endpoint()
        var override = AppPreferencesStore.shared.remoteModelOverride(endpoint: endpoint)
            ?? RemoteModelOverride()
        override.reasoningEffort = effort
        AppPreferencesStore.shared.saveRemoteModelOverride(override, endpoint: endpoint)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu.fill")
                .foregroundStyle(Theme.accent)
            Text(source == .local ? "Local model" : source == .api ? "API model" : "OpenAI account")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            switch appState.enginePhase {
            case .ready:
                statusBadge("Ready", color: Theme.success, icon: "checkmark.circle.fill")
            case .loading:
                statusBadge("Loading…", color: Theme.warning, icon: "hourglass")
            case .failed:
                statusBadge("Failed", color: Theme.danger, icon: "exclamationmark.triangle.fill")
            case .idle:
                statusBadge("Idle", color: Theme.textSecondary, icon: "circle")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func statusBadge(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.wash(color)))
    }

    // MARK: Local models

    @ViewBuilder
    private var localSection: some View {
        sectionLabel("On this Mac")
        if installedModels.isEmpty {
            Text("No local models yet — download one in the Model Manager.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 2)
        } else {
            ForEach(installedModels) { model in
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: CatalogModel) -> some View {
        let isActive = appState.activeModelID == model.id
        let loadingThis = appState.enginePhase == .loading(model.displayName)
        let budget = appState.budget(for: model)
        return Button {
            dismiss()
            Task { await appState.activate(model: model) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "cpu")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(model.parameters) · \(model.quantization) · \(isActive ? "active" : budgetHint(budget))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if loadingThis {
                    ProgressView().controlSize(.small)
                } else if isActive {
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.success)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isActive ? Theme.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(loadingThis || (!isActive && !budget.verdict.fitsLoad))
        .help(isActive ? "Active model. Its memory was admitted safely when it loaded." : budget.helpText)
    }

    private func budgetHint(_ budget: MemoryAdvisor.Budget) -> String {
        switch budget.verdict {
        case .fits: return "fits in RAM"
        case .marginal: return "tight fit"
        case .wontFit: return "won't fit"
        }
    }

    // MARK: API models

    @ViewBuilder
    private var apiSection: some View {
        sectionLabel("Configured API models")
        if remoteModels.isEmpty {
            HStack(spacing: 6) {
                Text("No API models configured yet.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Add provider…") {
                    dismiss()
                    // The Settings scene can't be opened via Notification —
                    // use the system action that raises it.
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 2)
        } else {
            ForEach(remoteModels) { profile in
                apiModelRow(profile)
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        sectionLabel("ChatGPT account models")
        if !codexAccount.isAvailable {
            Text("Codex CLI is not available on this Mac. Install Codex, then reopen Beet Code.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !codexAccount.isSignedIn {
            VStack(alignment: .leading, spacing: 8) {
                Text("Use OpenAI models with your ChatGPT account. API keys are not required for this mode.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign in with ChatGPT…") {
                    Task { await codexAccount.signInWithBrowser() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
            }
        } else if codexAccount.models.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading account models…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Refresh") { Task { await codexAccount.refreshModels() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
            }
        } else {
            ForEach(codexAccount.models) { model in
                codexModelRow(model)
            }
        }
        if let error = codexAccount.errorMessage {
            Text(error)
                .font(.caption2)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codexModelRow(_ model: CodexModelProfile) -> some View {
        let isActive = appState.isCodexActive && appState.activeCodexModelID == model.id
        return Button {
            Task {
                if await appState.activateCodex(model: model) { dismiss() }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(model.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !model.description.isEmpty {
                        Text(model.description)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.success)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isActive ? Theme.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Use OpenAI account model (model.id)")
    }

    private func apiModelRow(_ profile: RemoteModelProfile) -> some View {
        let provider = profile.provider
        let activeEndpoint = appState.engine.activeRemoteEndpoint
        let isActive = appState.isRemoteActive
            && activeEndpoint?.provider == provider
            && activeEndpoint?.providerID == profile.providerKey
            && activeEndpoint?.model == profile.model
        return Button {
            dismiss()
            Task {
                _ = await appState.activateRemote(endpoint: profile.endpoint())
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "cloud")
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName ?? profile.model)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text("\(profile.displayProviderName) · \(profile.model)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(profileMetadataSummary(profile))
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if isActive {
                    Text("Active")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.success)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isActive ? Theme.accentSoft : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Use \(profile.displayProviderName) / \(profile.model)")
    }

    private func profileMetadataSummary(_ profile: RemoteModelProfile) -> String {
        var parts: [String] = []
        if let context = profile.contextWindow {
            parts.append("\(context.formatted()) context")
        }
        if profile.supportsTools == true { parts.append("tools") }
        if profile.supportsReasoning == true { parts.append("reasoning") }
        if profile.supportsVision == true { parts.append("vision") }
        return parts.isEmpty ? "Capabilities unknown · configurable in Settings" : parts.joined(separator: " · ")
    }

    // MARK: Footer actions

    private var footer: some View {
        HStack(spacing: 10) {
            if appState.activeModelID != nil || appState.isRemoteActive || appState.isCodexActive {
                Button {
                    dismiss()
                    Task { await appState.deactivate() }
                } label: {
                    Label("Unload", systemImage: "eject")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Unload the current model and free its memory")
            }
            Spacer()
            Button {
                dismiss()
                if source == .account {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .openProviderSettings, object: nil)
                    }
                } else {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
            } label: {
                    Label(source == .local ? "Model Manager…" : source == .api ? "Manage API models…" : "Manage account…",
                          systemImage: source == .local ? "square.and.arrow.down.on.square" : source == .api ? "key" : "person.crop.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .help(source == .account ? "Open OpenAI account settings" : "Download more models, import folders, manage providers")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 4)
    }
}

/// Compact, model-aware reasoning selector shown beside the model list. The
/// control is deliberately visible (rather than buried in Settings) because
/// reasoning effort changes latency, token use, and answer depth for the very
/// next turn.
private struct ReasoningModelControl: View {
    let modelName: String
    let options: [String]
    let defaultEffort: String?
    @Binding var selection: String?
    let onSelect: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Theme.accent)
                Text("Reasoning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(selection?.capitalized ?? "Auto")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.accent)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    effortButton(title: "Auto", value: nil)
                    ForEach(normalizedOptions, id: \.self) { effort in
                        effortButton(title: effort.capitalized, value: effort)
                    }
                }
            }

            Text("For \(modelName) · Auto uses \((defaultEffort ?? "the model default").lowercased())")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(9)
        .background(Theme.surfaceInset.opacity(0.62), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .padding(.vertical, 2)
    }

    private var normalizedOptions: [String] {
        var seen = Set<String>()
        return options.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func effortButton(title: String, value: String?) -> some View {
        let selected = selection == value
        return Button {
            selection = value
            onSelect(value)
        } label: {
            Text(title)
                .font(.caption2.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(minHeight: 25)
                .background(selected ? Theme.washStrong(Theme.accent) : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Theme.washBorder(Theme.accent) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(value == nil ? "Use the model's default reasoning effort" : "Use \(title) reasoning for the next turn")
        .accessibilityLabel("Reasoning effort \(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Budget help text

private extension MemoryAdvisor.Budget {
    var helpText: String {
        "Projected peak memory: \(ByteFormatter.bytes(projectedFootprint))"
    }
}
