import AppKit
import SwiftUI

/// Appearance, input, and launch behaviour. Server endpoints moved to the
/// Network tab and the Hugging Face token to Providers, where it sits beside
/// the other credentials it belongs with.
struct GeneralTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        TabScroll {
            SettingsCard(
                title: "Appearance",
                icon: "paintbrush",
                footer: "Every accent is checked for contrast in both light and dark, so no palette makes text harder to read. Typeface changes prose and chrome only — code, diffs, and terminals stay monospaced.") {
                SettingRow(label: "Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingRow(label: "Accent", value: settings.accentPalette.label) {
                    PaletteSwatchPicker(selection: $settings.accentPalette)
                }

                SettingRow(label: "Typeface", value: settings.typeface.help) {
                    Picker("Typeface", selection: $settings.typeface) {
                        ForEach(AppTypeface.allCases) { face in
                            Text(face.label).tag(face)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }

                SettingRow(label: "Text size", value: settings.textSize.label) {
                    Picker("Text size", selection: $settings.textSize) {
                        ForEach(AppTextSize.allCases) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
            }

            SettingsCard(title: "Composer", icon: "text.cursor", footer: "Motion reflects interaction state and automatically stops when Reduce Motion is enabled. Response style controls the agent’s final handoff.") {
                SettingRow(label: "Border motion", value: settings.composerFlow.help) {
                    Picker("Border motion", selection: $settings.composerFlow) {
                        ForEach(ComposerFlow.allCases) { flow in
                            Text(flow.label).tag(flow)
                        }
                    }
                    .labelsHidden()
                }
                SettingRow(label: "Response style", value: settings.outputStyle.help) {
                    Picker("Response style", selection: $settings.outputStyle) {
                        ForEach(ProjectPolicy.OutputStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                }
                SettingToggle(label: "Animate interaction border", isOn: $settings.composerBorderAnimation)
            }

            SettingsCard(title: "Keyboard", icon: "keyboard", footer: "Shortcuts accept readable forms such as cmd+return. Esc always stops a running agent, and ⇧⌘M opens Model Manager.") {
                SettingToggle(label: "Enter sends", isOn: $settings.enterSends)
                Text(settings.enterSends
                     ? "Enter sends the message; Shift+Enter inserts a newline. The configured Send shortcut also works anywhere."
                     : "Enter inserts a newline. Use the configured Send shortcut to send.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                SettingRow(label: "Send shortcut", value: ShortcutBinding(rawValue: settings.sendShortcut).displayValue) {
                    ShortcutEditor(placeholder: "cmd+return", value: $settings.sendShortcut)
                }
                SettingRow(label: "Stop shortcut", value: ShortcutBinding(rawValue: settings.stopShortcut).displayValue) {
                    ShortcutEditor(placeholder: "cmd+.", value: $settings.stopShortcut)
                }
                SettingRow(label: "Plan shortcut", value: ShortcutBinding(rawValue: settings.planShortcut).displayValue) {
                    ShortcutEditor(placeholder: "cmd+shift+p", value: $settings.planShortcut)
                }
            }

            SettingsCard(title: "Launch", icon: "power", footer: "Downloads that were interrupted by quitting resume automatically next launch. When off, they appear paused in the Model Manager for explicit resume.") {
                SettingToggle(label: "Auto-resume interrupted downloads", isOn: Binding(
                    get: { AppPreferencesStore.shared.current.autoResumeDownloads },
                    set: { newValue in
                        var preferences = AppPreferencesStore.shared.current
                        preferences.autoResumeDownloads = newValue
                        AppPreferencesStore.shared.save(preferences)
                    }))
            }

        }
    }
}
