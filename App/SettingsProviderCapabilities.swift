import AppKit
import SwiftUI

enum CapabilityMode: String, CaseIterable, Identifiable {
    case automatic = "Auto"
    case enabled = "On"
    case disabled = "Off"

    var id: String { rawValue }

    var value: Bool? {
        switch self {
        case .automatic: nil
        case .enabled: true
        case .disabled: false
        }
    }

    init(value: Bool?) {
        switch value {
        case .some(true): self = .enabled
        case .some(false): self = .disabled
        case .none: self = .automatic
        }
    }
}

/// Native effort picker. Selection is `nil` for the provider default.
struct ReasoningEffortPicker: View {
    let profile: RemoteModelProfile
    @Binding var selection: String?

    private var options: [ReasoningEffort] { profile.effectiveReasoningEfforts }

    var body: some View {
        if !options.isEmpty {
            HStack {
                Text("Reasoning")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Picker("Reasoning", selection: $selection) {
                    Text("Auto").tag(Optional<String>.none)
                    ForEach(options) { option in
                        Text(option.label).tag(Optional(option.rawValue))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .help(selectionDetail)
            }
        }
    }

    private var selectionDetail: String {
        if let selected = options.first(where: { $0.rawValue == selection?.lowercased() }) {
            return selected.detail
        }
        if let defaultEffort = profile.effectiveDefaultReasoningEffort {
            return "The provider chooses its default · currently \(defaultEffort)"
        }
        return "The provider chooses the balance automatically"
    }
}

/// Capability controls for a model whose endpoint identity may come from
/// OpenCode or another compatible gateway. The override is keyed by the
/// exact provider id + model pair, so two gateways using the same model name
/// cannot accidentally share limits or tool flags.
struct RemoteModelCapabilityEditor: View {
    let profile: RemoteModelProfile

    @State private var contextWindow = ""
    @State private var outputTokens = ""
    @State private var vision: CapabilityMode = .automatic
    @State private var tools: CapabilityMode = .automatic
    @State private var reasoning: CapabilityMode = .automatic
    @State private var reasoningEffort: String?
    @State private var temperature: CapabilityMode = .automatic

    init(profile: RemoteModelProfile) {
        self.profile = profile
        let override = AppPreferencesStore.shared.remoteModelOverride(endpoint: profile.endpoint())
        _contextWindow = State(initialValue: override?.contextWindow.map(String.init) ?? "")
        _outputTokens = State(initialValue: override?.maxOutputTokens.map(String.init) ?? "")
        _vision = State(initialValue: CapabilityMode(value: override?.supportsVision))
        _tools = State(initialValue: CapabilityMode(value: override?.supportsTools))
        _reasoning = State(initialValue: CapabilityMode(value: override?.supportsReasoning))
        _reasoningEffort = State(initialValue: override?.reasoningEffort)
        _temperature = State(initialValue: CapabilityMode(value: override?.supportsTemperature))
    }

    private var effectiveProfile: RemoteModelProfile {
        profile.applying(AppPreferencesStore.shared.remoteModelOverride(endpoint: profile.endpoint()))
    }

    var body: some View {
        DisclosureGroup("Model capability overrides") {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(effectiveSummary)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Spacing.sm) {
                    TextField("Context window", text: $contextWindow)
                        .vampField()
                        .font(.caption.monospaced())
                    TextField("Max output", text: $outputTokens)
                        .vampField()
                        .font(.caption.monospaced())
                }

                capabilityPicker("Tools", selection: $tools)
                capabilityPicker("Reasoning", selection: $reasoning)
                ReasoningEffortPicker(profile: effectiveProfile, selection: $reasoningEffort)
                capabilityPicker("Vision", selection: $vision)
                capabilityPicker("Temperature", selection: $temperature)

                HStack {
                    Text("Only this provider/model is changed. API keys stay in Keychain.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.sm)
                    Button("Reset") { reset() }
                        .buttonStyle(LFCapsuleButtonStyle())
                        .controlSize(.small)
                    Button("Save") { save() }
                        .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                        .tint(Theme.accent)
                        .controlSize(.small)
                }
            }
            .padding(.top, Spacing.xs)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.textSecondary)
        .accessibilityHint("Set context, output, and feature support for \(profile.model).")
    }

    private var effectiveSummary: String {
        var parts: [String] = []
        if let context = effectiveProfile.contextWindow { parts.append("context \(context.formatted())") }
        if let output = effectiveProfile.maxOutputTokens { parts.append("output \(output.formatted())") }
        if effectiveProfile.supportsTools == true { parts.append("tools") }
        if !effectiveProfile.effectiveReasoningEfforts.isEmpty { parts.append("reasoning") }
        if effectiveProfile.supportsVision == true { parts.append("vision") }
        if effectiveProfile.supportsTemperature == true { parts.append("temperature") }
        return parts.isEmpty ? "Effective metadata is unknown — use the controls below for this gateway." : parts.joined(separator: " · ")
    }

    private func capabilityPicker(_ title: String, selection: Binding<CapabilityMode>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(CapabilityMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func save() {
        let override = RemoteModelOverride(
            contextWindow: positiveInt(contextWindow),
            maxOutputTokens: positiveInt(outputTokens),
            supportsVision: vision.value,
            supportsTools: tools.value,
            supportsReasoning: reasoning.value,
            supportsTemperature: temperature.value,
            reasoningEffort: reasoningEffort)
        AppPreferencesStore.shared.saveRemoteModelOverride(override, endpoint: profile.endpoint())
    }

    private func reset() {
        contextWindow = ""
        outputTokens = ""
        vision = .automatic
        tools = .automatic
        reasoning = .automatic
        temperature = .automatic
        reasoningEffort = nil
        AppPreferencesStore.shared.saveRemoteModelOverride(nil, endpoint: profile.endpoint())
    }

    private func positiveInt(_ text: String) -> Int? {
        let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return value.flatMap { $0 > 0 ? $0 : nil }
    }
}
