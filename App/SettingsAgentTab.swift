import AppKit
import SwiftUI

struct AgentTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        TabScroll {
            SettingsCard(title: "Autonomy", icon: "shield.lefthalf.filled", footer: "Reads run automatically. Writes and commands need approval unless you enable the safe-command policy.") {
                SettingRow(label: "Agent mode", value: settings.agentMode.help) {
                    Picker("Agent mode", selection: $settings.agentMode) {
                        ForEach(AgentMode.allCases) { mode in
                            Label(mode.label, systemImage: mode.icon).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Auto-approve file edits", isOn: $settings.autoApproveEdits)
                SettingToggle(label: "Auto-approve safe commands", isOn: $settings.autoApproveCommands)
            }

            SettingsCard(title: "Generation", icon: "slider.horizontal.3", footer: "Thermal policy caps these automatically when the Mac gets hot.") {
                SettingRow(label: "Max agent turns") {
                    stepperControl(label: "Max agent turns", value: $settings.maxTurns, range: 5...100, step: 1)
                }
                SettingRow(label: "Max tokens per turn") {
                    stepperControl(label: "Max tokens per turn", value: $settings.maxTokensPerTurn, range: 256...8192, step: 256)
                }
                SettingRow(label: "Temperature") {
                    HStack(spacing: Spacing.sm) {
                        Slider(value: $settings.temperature, in: 0...1.5, step: 0.05)
                            .frame(width: 220)
                        // Fixed-width value label so the slider never reflows.
                        Text(String(format: "%.2f", settings.temperature))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            ExperimentalInferenceCard()

            SettingsCard(
                title: "Memory & Context",
                icon: "brain",
                footer: "Memory and compression still feed the agent. The status-bar inspector is optional chrome, not part of the coding path.") {
                SettingRow(label: "Memory") {
                    Picker("Memory", selection: $settings.memoryMode) {
                        ForEach(MemoryMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                SettingRow(label: "Context compression") {
                    Picker("Context compression", selection: $settings.compressionLevel) {
                        ForEach(CompressionLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Plan mode (approve plan before tools run)", isOn: $settings.planMode)
                SettingToggle(label: "Show model reasoning (think blocks)", isOn: $settings.showReasoning)
                SettingToggle(
                    label: "Show workspace context inspector",
                    isOn: $settings.intelligenceInspectorEnabled)
            }

            SettingsCard(title: "Safety", icon: "checkmark.seal", footer: "Snapshots the working tree before each approved edit batch so any agent action can be undone. Verification runs the detected build or test checks after each successful edit — through the same approval card as any other command, never silently.") {
                SettingToggle(label: "Git checkpoints before edits", isOn: $settings.checkpointingEnabled)
                SettingToggle(label: "Verify edits with project checks", isOn: $settings.verifyAfterEdits)
            }

            ComputerControlCard()
        }
    }

    /// Value + stepper cluster shared by both numeric rows: the current value
    /// stays visible inside the control, right-aligned and monospaced.
    private func stepperControl(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack(spacing: Spacing.sm) {
            Text("\(value.wrappedValue)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 40, alignment: .trailing)
            Stepper(label, value: value, in: range, step: step)
                .labelsHidden()
        }
    }
}

/// Isolated experimental inference surface. It observes live engine status
/// without widening the invalidation scope of the ordinary generation card.
private struct ExperimentalInferenceCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        SettingsCard(
            title: "Experimental inference",
            icon: "bolt.badge.clock",
            footer: "Off by default and independently reversible. Reload the model after changing a setting. MLX prompt reuse keeps only an in-memory verified prefix; KV8 compresses eligible attention cache after 512 tokens without changing model files. Vision models are excluded. A failed MLX experiment retries with full replay and standard KV before showing an error."
        ) {
            SettingToggle(
                label: "DFlash for Qwen3.5 9B GGUF",
                isOn: $settings.experimentalDFlashEnabled)
            SettingToggle(
                label: "N-gram acceleration for other GGUF models",
                isOn: $settings.experimentalNGramEnabled)
            SettingToggle(
                label: "Reuse verified MLX prompt prefixes",
                isOn: $settings.experimentalMLXPromptCacheEnabled)
            SettingToggle(
                label: "Use 8-bit MLX KV cache after 512 tokens",
                isOn: $settings.experimentalMLXQuantizedKVEnabled)

            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusText: LocalizedStringResource {
        if appState.activeModel?.format == .mlx {
            let promptCache = appState.lastEngineStats.mlxPromptCacheActive
            let kv8 = appState.lastEngineStats.mlxQuantizedKVActive
            if promptCache && kv8 {
                return "Verified prompt reuse and 8-bit KV cache are active."
            }
            if promptCache {
                return "Verified MLX prompt reuse is active."
            }
            if kv8 {
                return "8-bit MLX KV cache is active."
            }
            if settings.experimentalMLXPromptCacheEnabled
                || settings.experimentalMLXQuantizedKVEnabled
            {
                return "MLX experiments are enabled; reload the model to apply or retry them."
            }
            return "Standard MLX prompt replay and KV cache are active."
        }

        switch appState.lastEngineStats.acceleration {
        case .dflash:
            return "DFlash is active for the loaded model."
        case .mtp:
            return settings.experimentalDFlashEnabled
                ? "The loaded model is using the MTP fallback."
                : "The loaded model is using built-in MTP."
        case .ngram:
            return "N-gram speculative decoding is active for the loaded model."
        case .standard:
            if !anyExperimentEnabled {
                return "Standard decoding is active."
            }
            return "Experiments are enabled; select and reload a compatible model."
        }
    }

    private var statusColor: Color {
        switch appState.lastEngineStats.acceleration {
        case .dflash: Theme.success
        case .mtp: Theme.info
        case .ngram: Theme.info
        case .standard:
            anyExperimentEnabled
                ? Theme.warning : Theme.textTertiary
        }
    }

    private var anyExperimentEnabled: Bool {
        settings.experimentalDFlashEnabled
            || settings.experimentalNGramEnabled
            || settings.experimentalMLXPromptCacheEnabled
            || settings.experimentalMLXQuantizedKVEnabled
    }
}

/// Computer-use tools stay out of the agent until this switch is on.
/// TCC rows only appear after opt-in so a first-run user is not asked
/// for Accessibility just by opening Settings.
private struct ComputerControlCard: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false

    var body: some View {
        SettingsCard(
            title: "Computer control",
            icon: "desktopcomputer.and.arrow.down",
            footer: settings.computerControlEnabled
                ? "Off the coding path by default. Observation is automatic; clicks, keys, and scrolls still need approval. Revoke in System Settings → Privacy & Security."
                : "Off by default. When enabled, the agent can inspect and drive other Mac apps through the approval card."
        ) {
            SettingToggle(
                label: "Allow the agent to control other Mac apps",
                isOn: $settings.computerControlEnabled)
            if settings.computerControlEnabled {
                permissionRow(
                    label: "Accessibility",
                    value: "Read app UI trees; post mouse & keyboard events",
                    granted: accessibilityGranted,
                    grant: { ComputerPermission.requestAccessibility() })
                permissionRow(
                    label: "Screen Recording",
                    value: "Capture windows for vision models",
                    granted: screenRecordingGranted,
                    grant: { ComputerPermission.requestScreenRecording() })
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: settings.computerControlEnabled) { _, enabled in
            if enabled { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func permissionRow(
        label: String,
        value: String,
        granted: Bool,
        grant: @escaping () -> Void
    ) -> some View {
        SettingRow(label: label, value: value) {
            HStack(spacing: Spacing.sm) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(granted ? Theme.accentBright : Theme.textTertiary)
                        .frame(width: 7, height: 7)
                    Text(granted ? "Granted" : "Not granted")
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !granted {
                    Button("Grant…", action: grant)
                        .controlSize(.small)
                }
            }
        }
    }

    private func refresh() {
        accessibilityGranted = ComputerPermission.accessibilityGranted
        screenRecordingGranted = ComputerPermission.screenRecordingGranted
    }
}
