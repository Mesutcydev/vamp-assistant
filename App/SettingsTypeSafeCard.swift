import SwiftUI

// MARK: - TypeSafe guardrails

/// TypeSafe (System One) guardrails — the key plus the two behaviour toggles.
/// Deliberately its own card rather than a provider row: TypeSafe is not an
/// OpenAI-compatible chat endpoint, so it can never serve as the agent's
/// model. It decides; the model talks.
struct TypeSafeSettingsCard: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var keyStore = TypeSafeKeyStore.shared
    @State private var keyDraft = ""
    @State private var modelDraft = ""

    enum TestState: Equatable {
        case idle
        case running
        case ok(String)
        case failed(String)
    }
    @State private var testState: TestState = .idle

    private var hasKey: Bool { keyStore.hasKey }

    private var enabled: Bool {
        settings.typeSafeContentScreening || settings.typeSafeCommandEscalation
    }

    var body: some View {
        SettingsCard(
            title: "TypeSafe Guardrails",
            icon: "shield.lefthalf.filled",
            footer: "System One (Jev) answers typed questions with probabilities, so it is used for judgements, not for chat. Both guardrails only ever ADD caution: they can label content and force an approval card, never approve anything and never relax the command policy. If TypeSafe is unreachable the local instruction scan still labels content, and everything else behaves exactly as it did before. Billing is input tokens only (output tokens are free)."
        ) {
            HStack(spacing: Spacing.sm) {
                if hasKey {
                    badge("Configured", systemImage: "checkmark.seal.fill", tint: Theme.success)
                } else {
                    badge("No key", systemImage: "key.slash", tint: Theme.textTertiary)
                }
                if hasKey && enabled {
                    badge("Active", systemImage: "shield.lefthalf.filled", tint: Theme.info)
                }
                Spacer()
                if hasKey {
                    Button("Remove key", role: .destructive) {
                        keyStore.delete()
                        keyDraft = ""
                        testState = .idle
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            HStack(spacing: Spacing.sm) {
                SecureField(hasKey ? "API key (replace)" : "API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Button("Save") {
                    if !keyDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                        keyStore.save(keyDraft)
                    }
                    keyDraft = ""
                    testState = .idle
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            SettingRow(label: "Model") {
                HStack(spacing: Spacing.sm) {
                    TextField(TypeSafeClient.defaultModel, text: $modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .autocorrectionDisabled()
                    Button("Use") {
                        settings.typeSafeModel = modelDraft
                        modelDraft = ""
                        testState = .idle
                    }
                    .buttonStyle(.bordered)
                    .disabled(modelDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Pinned to a versioned id by default: the `jev-latest` alias has served transient 503 “model unavailable” responses while the versioned id answered moments later.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Spacing.sm) {
                Button("Test connection") { runTest() }
                    .buttonStyle(.bordered)
                    .disabled(!hasKey || testState == .running)
                switch testState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.small)
                case .ok(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                        .lineLimit(2)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(3)
                }
            }

            SettingToggle(
                label: "Screen untrusted content before the model reads it",
                isOn: $settings.typeSafeContentScreening)
            Text("Web pages and evaluated page values are judged for agent-directed instructions and credential bait; flagged content is labeled and its instruction-like lines are redacted.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            SettingToggle(
                label: "Escalate destructive actions to an approval card",
                isOn: $settings.typeSafeCommandEscalation)
            Text("Only ever applies where the permission gate would have acted silently (Auto or Full Access) — the deterministic gate still decides everything else.")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            thresholdControl(label: "Flag above probability", value: $settings.typeSafeScreeningThreshold)
            thresholdControl(label: "Escalate above probability", value: $settings.typeSafeEscalationThreshold)
        }
    }

    private func thresholdControl(label: String, value: Binding<Double>) -> some View {
        SettingRow(label: label) {
            HStack(spacing: Spacing.sm) {
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(minWidth: 40, alignment: .trailing)
                Stepper(label, value: value, in: 0.1...0.99, step: 0.05)
                    .labelsHidden()
            }
        }
    }

    private func runTest() {
        testState = .running
        Task { @MainActor in
            do {
                let models = try await keyStore.validateStored()
                testState = .ok(models.isEmpty
                    ? "Connected."
                    : "Connected — models: \(models.joined(separator: ", "))")
            } catch {
                let description = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                testState = .failed(description)
            }
        }
    }

    private func badge(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}
