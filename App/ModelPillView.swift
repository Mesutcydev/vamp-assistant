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
                    .font(.app(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(iconColor)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.app(size: 8, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.textTertiary)
            }
            // Model identity is a text control in the command line, not a
            // competing badge. The status dot carries readiness at a glance.
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .frame(minHeight: 26)
            .background(showPopover ? Theme.washStrong(Theme.accent) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
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
                // A fixed box, not a content-sized one: with a few hundred
                // gateway models the popover used to grow to the full screen
                // height and push its own search field off the top.
                .frame(width: 400, height: 520)
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

        /// Segment title. The full `label` does not fit three-across once each
        /// segment also carries a count.
        var shortLabel: String {
            switch self {
            case .local: "Local"
            case .api: "API"
            case .account: "Account"
            }
        }
    }
    @State private var source: Source = .local
    @State private var reasoningEffort: String?
    @State private var query = ""
    @State private var allRemoteModels: [RemoteModelProfile] = []
    @State private var refreshingCatalog = false
    @State private var refreshMessage: String?
    @FocusState private var searchFocused: Bool

    /// Case- and diacritic-insensitive substring match across every string a
    /// user might type: display name, raw model id, and provider name. Search
    /// used to look at the display name alone, so typing an exact model id
    /// like `claude-sonnet-4-5` matched nothing.
    private func matches(_ candidates: String?...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return candidates.contains { candidate in
            guard let candidate else { return false }
            return candidate.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Chat models only — vision sidecars are never loadable here; the app
    /// runs them automatically for image attachments.
    private var allInstalledModels: [CatalogModel] {
        ModelCatalog.all.filter {
            $0.role == .chat && appState.modelStore.isInstalled(catalogModel: $0)
        }
    }

    private var installedModels: [CatalogModel] {
        allInstalledModels.filter { matches($0.displayName, $0.id) }
    }

    private var remoteProviders: [LLMProvider] {
        APIKeyStore.shared.configuredProviders.sorted { $0.displayName < $1.displayName }
    }

    /// Built once per popover open. Assembling it walks every configured
    /// provider, every saved live profile, and every OpenCode import — far too
    /// much to redo on each keystroke, which is what a computed property meant
    /// once the counts on the source picker also read it.
    private func buildRemoteModels() -> [RemoteModelProfile] {
        RemoteAPIModelCatalog.profiles(
            configuredProviders: Set(remoteProviders),
            selectedModelByProvider: AppPreferencesStore.shared.current.remoteModel,
            savedProfiles: Array(AppPreferencesStore.shared.current.remoteModelProfiles.values),
            hasKeyForProviderID: { keyStore.hasKey(forProviderID: $0) },
            openCodeProfiles: appState.openCodeCatalog.models.map { $0.remoteProfile() }
        )
        .map { $0.applying(AppPreferencesStore.shared.remoteModelOverride(endpoint: $0.endpoint())) }
    }

    private var remoteModels: [RemoteModelProfile] {
        allRemoteModels.filter { matches($0.displayName, $0.model, $0.displayProviderName) }
    }

    private var allAccountModels: [CodexModelProfile] { codexAccount.models }

    private var accountModels: [CodexModelProfile] {
        allAccountModels.filter { matches($0.displayName, $0.id) }
    }

    /// Unfiltered totals, shown on the source picker so the size of each list
    /// is visible before you switch to it.
    private func total(for source: Source) -> Int {
        switch source {
        case .local: allInstalledModels.count
        case .api: allRemoteModels.count
        case .account: allAccountModels.count
        }
    }

    private var visibleCount: Int {
        switch source {
        case .local: installedModels.count
        case .api: remoteModels.count
        case .account: accountModels.count
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // Pinned: source, search, and the result count stay put while the
            // list scrolls under them. They used to sit inside the ScrollView,
            // so the moment you scrolled a long list the search box was gone.
            VStack(alignment: .leading, spacing: 8) {
                Picker("Model source", selection: $source) {
                    ForEach(Source.allCases) { option in
                        Text(total(for: option) > 0
                             ? "\(option.shortLabel) \(total(for: option))"
                             : option.shortLabel)
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                searchField
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if source == .local {
                        localSection
                    } else if source == .api {
                        apiSection
                    } else {
                        accountSection
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            if hasReasoningControl {
                Divider()
                activeReasoningControl
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
            allRemoteModels = buildRemoteModels()
            loadReasoningEffort()
            searchFocused = true
        }
        // A key saved elsewhere while this popover is open changes what is
        // usable, so rebuild rather than showing a stale catalog.
        .onReceive(keyStore.objectWillChange) { _ in
            allRemoteModels = buildRemoteModels()
        }
        .onChange(of: source) { _, _ in loadReasoningEffort() }
        .onChange(of: appState.activeCodexModelID) { _, _ in loadReasoningEffort() }
        .onChange(of: appState.engine.activeRemoteEndpoint) { _, _ in loadReasoningEffort() }
    }

    /// Whether `activeReasoningControl` will render anything — checked before
    /// drawing its divider so an empty control never leaves a stray hairline.
    private var hasReasoningControl: Bool {
        if source == .api, let profile = activeRemoteReasoningProfile {
            return !profile.effectiveReasoningEfforts.isEmpty
        }
        if source == .account, let model = activeCodexReasoningModel {
            return !model.supportedReasoningEfforts.isEmpty
        }
        return false
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
                .foregroundStyle(Theme.accentText)
            Text(activeModelLabel)
                .font(.app(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
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

    /// The header names the model that is actually loaded — the segmented
    /// picker below already says which list you are browsing, so repeating
    /// "Local model" there was a wasted line.
    private var activeModelLabel: String {
        switch appState.enginePhase {
        case .ready(let name), .loading(let name): name
        case .failed, .idle: appState.activeModel?.displayName ?? "No model loaded"
        }
    }

    private func statusBadge(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.app(size: 11, weight: .medium, design: .serif))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.wash(color)))
    }

    /// Filters whichever source is showing. One field rather than one per section: the source
    /// picker already says which list is on screen, and the lists are long enough that scrolling
    /// to a known model name was the slow part. Matches name, model id, and provider.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            TextField("Search name, model id, or provider", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
            if query.isEmpty {
                Text("\(visibleCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text("\(visibleCount) of \(total(for: source))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear model search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Shown when a source has models but the query excluded all of them —
    /// distinct from "you have not configured anything yet".
    private var noMatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No model matches “\(query)”.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Button("Clear search") { query = "" }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accentText)
        }
        .padding(.vertical, 2)
    }

    // MARK: Local models

    @ViewBuilder
    private var localSection: some View {
        sectionLabel("On this Mac")
        if allInstalledModels.isEmpty {
            Text("No local models yet — download one in the Model Manager.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 2)
        } else if installedModels.isEmpty {
            noMatches
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
                    .accessibilityHidden(true)
                    .font(.app(size: 13, design: .serif))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.app(size: 12.5, weight: isActive ? .semibold : .regular, design: .serif))
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
        if !allRemoteModels.isEmpty, remoteModels.isEmpty {
            noMatches
        } else if remoteModels.isEmpty {
            HStack(spacing: 6) {
                Text("No API models configured yet.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Button("Add provider…") {
                    dismiss()
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accentText)
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
            Text("Codex CLI is not available on this Mac. Install Codex, then reopen Vamp Assistant.")
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
                    .foregroundStyle(Theme.accentText)
            }
        } else if accountModels.isEmpty {
            noMatches
        } else {
            ForEach(accountModels) { model in
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
                    .accessibilityHidden(true)
                    .font(.app(size: 13, design: .serif))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName)
                        .font(.app(size: 12.5, weight: isActive ? .semibold : .regular, design: .serif))
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
        .help("Use OpenAI account model \(model.id)")
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
                    .accessibilityHidden(true)
                    .font(.app(size: 13, design: .serif))
                    .foregroundStyle(isActive ? Theme.success : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.displayName ?? profile.model)
                        .font(.app(size: 12.5, weight: isActive ? .semibold : .regular, design: .serif))
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
                        .font(.app(size: 12, design: .serif))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("Unload the current model and free its memory")
            }
            if source == .api {
                if refreshingCatalog {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: refreshRemoteCatalog) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.app(size: 12, design: .serif))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(remoteProviders.isEmpty && KnownRemoteProvider.all.allSatisfy {
                        !keyStore.hasKey(forProviderID: $0.id)
                    })
                    .help("Ask every configured provider for its current model list")
                }
            }
            if let refreshMessage {
                Text(refreshMessage)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button {
                dismiss()
                if source == .account {
                    NotificationCenter.default.post(name: .openAppSettings, object: nil)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .openProviderSettings, object: nil)
                    }
                } else {
                    NotificationCenter.default.post(name: .openModelManager, object: nil)
                }
            } label: {
                    Label(source == .local ? "Model Manager…" : source == .api ? "Manage API models…" : "Manage account…",
                          systemImage: source == .local ? "square.and.arrow.down.on.square" : source == .api ? "key" : "person.crop.circle")
                    .font(.app(size: 12, design: .serif))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accentText)
            .help(source == .account ? "Open OpenAI account settings" : "Download more models, import folders, manage providers")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Pulls each configured provider's live `/models` list and saves the
    /// profiles. Without this the composer could only ever offer the curated
    /// fallback ids until you went to Settings and refreshed there — which is
    /// why the list looked short for gateways that serve hundreds of models.
    private func refreshRemoteCatalog() {
        refreshingCatalog = true
        refreshMessage = nil
        Task {
            var loaded = 0
            var failures = 0
            for provider in remoteProviders {
                guard let key = keyStore.key(for: provider), !key.isEmpty else { continue }
                do {
                    let profiles = try await RemoteLLMClient.fetchModelProfiles(
                        provider: provider, apiKey: key)
                    AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                    loaded += profiles.count
                } catch {
                    // A provider without a `/models` route is normal, not fatal:
                    // its curated ids and any manual entry stay usable.
                    failures += 1
                }
            }
            for known in KnownRemoteProvider.all {
                guard let key = keyStore.key(forProviderID: known.id), !key.isEmpty else { continue }
                do {
                    let profiles = try await RemoteLLMClient.fetchModelProfiles(
                        endpoint: known.endpoint(model: known.defaultModel), apiKey: key)
                    AppPreferencesStore.shared.saveRemoteModelProfiles(profiles)
                    loaded += profiles.count
                } catch {
                    failures += 1
                }
            }
            allRemoteModels = buildRemoteModels()
            refreshingCatalog = false
            refreshMessage = loaded > 0
                ? "\(allRemoteModels.count) models"
                : (failures > 0 ? "No provider returned a model list" : "Nothing to refresh")
        }
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
                    .accessibilityHidden(true)
                    .foregroundStyle(Theme.accentText)
                Text("Reasoning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(selection?.capitalized ?? "Auto")
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(Theme.accentText)
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
                .foregroundStyle(selected ? Theme.accentText : Theme.textSecondary)
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
