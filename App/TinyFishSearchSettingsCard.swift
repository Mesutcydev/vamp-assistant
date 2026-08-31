import AppKit
import SwiftUI

/// Optional TinyFish Search configuration for Vamp Assistant.
///
/// The search tool is intentionally useful without a project, so this card
/// lives alongside the other provider credentials instead of in a hidden
/// developer-only panel. The key is never mirrored into UserDefaults or the
/// session transcript.
struct TinyFishSearchSettingsCard: View {
    @State private var keyDraft = ""
    @State private var configured = false
    @State private var testing = false
    @State private var message: String?
    @State private var messageIsError = false

    var body: some View {
        SettingsCard(
            title: "TinyFish Search",
            icon: "magnifyingglass.circle",
            footer: "TinyFish returns ranked web sources and snippets for Vamp Assistant. Use web_fetch or the in-app browser to read and verify a result before acting on it. The API key stays in this Mac's Keychain.") {
            TinyFishSearchSummary(configured: configured)
            TinyFishSearchCredentialRow(
                configured: configured,
                keyDraft: $keyDraft,
                onSave: saveKey,
                onRemove: removeKey)
            TinyFishSearchActions(
                configured: configured,
                testing: testing,
                onTest: testConnection)

            Text("Create or rotate a key at agent.tinyfish.ai/api-keys. Search requests use HTTPS and are limited to a bounded response.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let message {
                Label(message, systemImage: messageIsError ? "exclamationmark.triangle" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(messageIsError ? Theme.danger : Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            configured = TinyFishSearchCredentialStore.isConfigured
        }
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            setMessage("Paste a TinyFish Search API key first.", error: true)
            return
        }
        guard TinyFishSearchCredentialStore.save(value) else {
            setMessage("The key could not be saved to the Mac Keychain.", error: true)
            return
        }
        configured = true
        keyDraft = ""
        setMessage("TinyFish Search is ready for Vamp Assistant.", error: false)
    }

    private func removeKey() {
        TinyFishSearchCredentialStore.delete()
        configured = false
        keyDraft = ""
        setMessage("TinyFish Search key removed.", error: false)
    }

    private func testConnection() {
        guard configured else { return }
        testing = true
        message = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let response = try await TinyFishSearchClient.search(
                    options: TinyFishSearchClient.Options(query: "Vamp Assistant", maxResults: 1))
                let count = response.results.count
                setMessage("Connected. TinyFish returned \(count) result\(count == 1 ? "" : "s").", error: false)
            } catch {
                setMessage(error.localizedDescription, error: true)
            }
        }
    }

    private func setMessage(_ value: String, error: Bool) {
        message = value
        messageIsError = error
    }
}

private struct TinyFishSearchSummary: View {
    let configured: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Live web search")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Structured search results · read-only · no browser control")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: Spacing.md)
            Label(
                configured ? "Configured" : "Not configured",
                systemImage: configured ? "checkmark.seal.fill" : "circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(configured ? Theme.success : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Theme.wash(configured ? Theme.success : Theme.textSecondary),
                    in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TinyFishSearchCredentialRow: View {
    let configured: Bool
    @Binding var keyDraft: String
    let onSave: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            SecureField(configured ? "Replace API key" : "Paste TinyFish API key", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textContentType(.password)
                .onSubmit(onSave)

            Button("Save", action: onSave)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.small)
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if configured {
                Button("Remove key", role: .destructive, action: onRemove)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
    }
}

private struct TinyFishSearchActions: View {
    let configured: Bool
    let testing: Bool
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button(action: onTest) {
                if testing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Testing TinyFish Search")
                } else {
                    Label("Test connection", systemImage: "checkmark.circle")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(testing || !configured)

            Button("Open TinyFish keys") {
                guard let url = URL(string: "https://agent.tinyfish.ai/api-keys") else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
    }
}
