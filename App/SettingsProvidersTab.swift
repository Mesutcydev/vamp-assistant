import AppKit
import SwiftUI

// MARK: - Providers tab

struct ProvidersTab: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var keyStore = APIKeyStore.shared
    /// Keys that survived the LocalForge rename inside the OLD Keychain
    /// services but could not be copied silently (their ACLs demand one
    /// interactive re-authorization). Banner offers the one-tap restore.
    @State private var pendingRestore = false
    @State private var restoreResult: String?

    @State private var query = ""
    @State private var selectedID: String?
    @State private var connectedOnly = false
    @ObservedObject private var codex = CodexAccountStore.shared

    var body: some View {
        TabScroll {
            if pendingRestore { keyRestoreBanner }
            HStack {
                VampSearchField(placeholder: "Find a provider", text: $query)
                Toggle("Connected only", isOn: $connectedOnly)
                    .toggleStyle(.checkbox)
                    .fixedSize()
            }
            Text("Connect once, then choose a model in any chat.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                if matches("ChatGPT", connected: codex.isSignedIn) {
                    ProviderDirectoryTile(name: "ChatGPT", subtitle: codex.isSignedIn ? "Connected account" : "Use your subscription", icon: "person.crop.circle", connected: codex.isSignedIn) { selectedID = "account" }
                }
                ForEach(LLMProvider.allCases.sorted { left, right in
                    let lhs = keyStore.hasKey(for: left)
                    let rhs = keyStore.hasKey(for: right)
                    return lhs != rhs ? lhs : left.displayName < right.displayName
                }.filter { matches($0.displayName, connected: keyStore.hasKey(for: $0)) }) { provider in
                    ProviderDirectoryTile(name: provider.displayName, subtitle: keyStore.hasKey(for: provider) ? "Connected · Manage" : "Connect with API key", icon: "cloud", connected: keyStore.hasKey(for: provider)) { selectedID = "api:" + provider.rawValue }
                }
                ForEach(KnownRemoteProvider.compatiblePresets.filter { matches($0.displayName, connected: keyStore.hasKey(forProviderID: $0.id)) }) { provider in
                    ProviderDirectoryTile(name: provider.displayName, subtitle: keyStore.hasKey(forProviderID: provider.id) ? "Connected · Manage" : "Connect with API key", icon: "network", connected: keyStore.hasKey(forProviderID: provider.id)) { selectedID = "known:" + provider.id }
                }
                ForEach(appState.openCodeCatalog.providers.filter { matches($0.id, connected: true) }) { provider in
                    ProviderDirectoryTile(name: provider.id, subtitle: "Imported from OpenCode", icon: "arrow.down.circle", connected: true) { selectedID = "import:" + provider.id }
                }
            }
            if connectedOnly {
                Button("Browse all providers") { connectedOnly = false }
                    .buttonStyle(.borderless)
            }
            DisclosureGroup("Search & downloads") {
                HStack(spacing: 12) {
                    Button("Web search…") { selectedID = "search" }
                    Button("Hugging Face downloads…") { selectedID = "downloads" }
                }
                .padding(.top, 12)
            }
            Text("Credentials are stored securely in your Mac’s Keychain.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
            // Not a provider tile: TypeSafe decides, it never answers the
            // conversation. See `TypeSafeSettingsCard`.
            TypeSafeSettingsCard()
        }
        .sheet(isPresented: Binding(get: { selectedID != nil }, set: { if !$0 { selectedID = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Connection settings").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Done") { selectedID = nil }.keyboardShortcut(.defaultAction)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if selectedID == "account" { CodexAccountCard() }
                        if selectedID == "search" { TinyFishSearchSettingsCard() }
                        if selectedID == "downloads" { HuggingFaceProviderCard() }
                        ForEach(LLMProvider.allCases) { provider in
                            if selectedID == "api:" + provider.rawValue { ProviderCard(provider: provider, initiallyExpanded: true) }
                        }
                        ForEach(KnownRemoteProvider.compatiblePresets) { provider in
                            if selectedID == "known:" + provider.id { KnownProviderRow(provider: provider) }
                        }
                        ForEach(appState.openCodeCatalog.providers) { provider in
                            if selectedID == "import:" + provider.id { OpenCodeProviderRow(provider: provider) }
                        }
                    }.padding(2)
                }
            }
            .padding(24)
            .frame(width: 640, height: 560)
            .background(Theme.surface)
            .environmentObject(appState)
        }
        .task { pendingRestore = LegacyMigration.needsInteractiveKeyMigration() }
        .task { await codex.refresh() }
    }

    private func matches(_ name: String, connected: Bool) -> Bool {
        (!connectedOnly || connected) && (query.isEmpty || name.localizedCaseInsensitiveContains(query))
    }

    private var keyRestoreBanner: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "key.fill")
                .accessibilityHidden(true)
                .font(.app(size: 13, weight: .semibold ))
                .foregroundStyle(Theme.warning)
                .frame(width: 30, height: 30)
                .background(Theme.surfaceInset,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Keys from LocalForge found")
                    .font(.app(size: 13, weight: .semibold ))
                    .foregroundStyle(Theme.textPrimary)
                Text("Your saved API keys are still in the Keychain under the old LocalForge app, but macOS requires one authorization to move them. Your keys were never deleted.")
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Spacing.md) {
                    Button("Restore Keys…") {
                        restoreKeys()
                    }
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    if let restoreResult {
                        Text(restoreResult)
                            .font(.app(size: 11.5 ))
                            .foregroundStyle(Theme.positive)
                    }
                }
            }
        }
        .vampOutlineCard()
    }

    /// Runs the interactive migration OFF the main actor — the Keychain
    /// authorization dialog is system-rendered, but the SecItem calls must
    /// not block SwiftUI while it is up.
    private func restoreKeys() {
        Task.detached(priority: .userInitiated) {
            let migrated = LegacyMigration.migrateInteractively()
            await MainActor.run {
                if migrated > 0 {
                    restoreResult = "Restored \(migrated) key\(migrated == 1 ? "" : "s")."
                    pendingRestore = LegacyMigration.needsInteractiveKeyMigration()
                    keyStore.objectWillChange.send()
                } else {
                    restoreResult = "Nothing restored — approve the Keychain prompt and try again."
                }
            }
        }
    }
}

/// Hub downloads and the Inference Router share one card so Settings is not
/// two Hugging Face rows.
struct HuggingFaceProviderCard: View {
    @ObservedObject private var tokenStore = HFTokenStore.shared
    @State private var tokenDraft = ""
    @State private var validationMessage: String?
    @State private var isValidating = false

    var body: some View {
        SettingsCard(
            title: "Hugging Face",
            icon: "arrow.down.circle",
            footer: "One Keychain token for gated Hub downloads. A separate router key is optional if you chat through router.huggingface.co.") {
            SecureField("Hub token (hf_…)", text: $tokenDraft)
                .vampField()
                .autocorrectionDisabled()
            HStack(spacing: Spacing.sm) {
                Button("Save") {
                    tokenStore.saveToken(tokenDraft)
                    validationMessage = "Saved to Keychain."
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .tint(Theme.accent)
                .disabled(tokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Validate") {
                    isValidating = true
                    validationMessage = nil
                    Task {
                        defer { isValidating = false }
                        do {
                            let name = try await tokenStore.validate(draft: tokenDraft)
                            tokenStore.saveToken(tokenDraft)
                            validationMessage = "Validated as \(name) — saved."
                        } catch {
                            validationMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(LFCapsuleButtonStyle())
                .disabled(isValidating || tokenDraft.isEmpty)

                if tokenStore.hasToken {
                    Button("Remove", role: .destructive) {
                        tokenStore.deleteToken()
                        tokenDraft = ""
                        validationMessage = "Token removed."
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
                Spacer()
                if isValidating { ProgressView().controlSize(.small) }
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let hf = KnownRemoteProvider.find("huggingface") {
                Text("Inference router")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Spacing.sm)
                KnownProviderRow(provider: hf, showsIdentity: false)
            }
        }
        .onAppear { tokenDraft = tokenStore.token() ?? "" }
    }
}

/// Account-backed OpenAI access is deliberately a separate card from BYOK:
/// ChatGPT sign-in is handled by Codex app-server, while API keys remain
/// independent Keychain credentials with usage-based billing.
struct CodexAccountCard: View {
    @ObservedObject private var codex = CodexAccountStore.shared
    @State private var copiedCode = false

    var body: some View {
        SettingsCard(
            title: "OpenAI account",
            icon: "person.crop.circle",
            footer: "Sign in with ChatGPT to use the models available to your account, including GPT-6 Astra. Vamp Assistant never asks for or stores the ChatGPT refresh token; the installed Codex app-server owns browser login, refresh, logout, tools, MCP, and approvals.") {
            HStack(alignment: .top, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(codex.isSignedIn ? "Connected to ChatGPT" : "Use OpenAI with your account")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.md)
                statusBadge
            }

            if !codex.isSignedIn {
                HStack(spacing: Spacing.sm) {
                    Button("Sign in with ChatGPT…") {
                        Task { await codex.signInWithBrowser() }
                    }
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                    .tint(Theme.accent)
                    .controlSize(.small)

                    Button("Use device code") {
                        Task { await codex.signInWithDeviceCode() }
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                    .controlSize(.small)
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    Button("Refresh models") {
                        Task { await codex.refreshModels() }
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                    .controlSize(.small)
                    Button("Sign out") {
                        Task { await codex.signOut() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.negative)
                    .controlSize(.small)
                }
            }

            if let deviceCode = codex.deviceCodeLogin {
                deviceCodeRow(deviceCode)
            } else if codex.browserLogin != nil {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Finish sign-in in your browser, then return to Vamp Assistant.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Cancel") { Task { await codex.cancelLogin() } }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            if let error = codex.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.negative)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await codex.refresh() }
    }

    private var accountSubtitle: String {
        if !codex.isAvailable { return "Codex CLI was not found. Install it to enable account login." }
        if let account = codex.account {
            return "\(account.displayPlan) · \(codex.models.count) models available in the composer"
        }
        return "Browser login or device code login opens the official Codex authentication flow. GPT-6 Astra is offered as the latest account model."
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            VampStatusDot(color: codex.isSignedIn ? Theme.positive : Theme.statusNeutral)
            Text(codex.isSignedIn ? "Connected" : (codex.isAvailable ? "Not connected" : "Unavailable"))
                .font(.app(size: 11, weight: .medium ))
                .foregroundStyle(codex.isSignedIn ? Theme.positive : Theme.textSecondary)
        }
    }

    private func deviceCodeRow(_ login: CodexDeviceCodeLogin) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Enter this code in the browser")
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textSecondary)
                Text(login.userCode)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            Button(copiedCode ? "Copied" : "Copy code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(login.userCode, forType: .string)
                copiedCode = true
            }
            .buttonStyle(LFCapsuleButtonStyle())
            Button("Open") { NSWorkspace.shared.open(login.verificationURL) }
                .buttonStyle(LFCapsuleButtonStyle())
            Button("Cancel") { Task { await codex.cancelLogin() } }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
        }
        .vampOutlineCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
    }
}

private struct ProviderDirectoryTile: View {
    let name: String
    let subtitle: String
    let icon: String
    let connected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: icon).font(.title3)
                        .foregroundStyle(connected ? Theme.positive : Instrument.accentOrange)
                        .frame(width: 34, height: 34)
                        .background((connected ? Instrument.signalGreen : Instrument.accentOrange).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    Spacer()
                    if connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.positive) }
                    Image(systemName: "arrow.up.right").foregroundStyle(Theme.textTertiary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline, lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(subtitle)")
    }
}
