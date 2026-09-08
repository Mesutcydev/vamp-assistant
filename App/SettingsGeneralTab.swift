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
                footer: "Every accent is checked for contrast in both light and dark, so no palette makes text harder to read. Typeface changes reading prose only — controls stay system sans, and code, diffs, and terminals stay monospaced.") {
                SettingRow(label: "Appearance") {
                    InstrumentSegmentedControl(
                        // Capture overrides are read-only and must not write
                        // the user's saved appearance or display a stale choice.
                        selection: DesignPreview.appearanceOverride.map { .constant($0) }
                            ?? $settings.appearance,
                        options: AppAppearance.allCases.map { ($0.label, $0) })
                    .frame(width: 280)
                    .accessibilityLabel("Appearance")
                }

                SettingRow(label: "Accent", value: settings.accentPalette.label) {
                    PaletteSwatchPicker(selection: $settings.accentPalette)
                }

                SettingRow(label: "Typeface", value: settings.typeface.help) {
                    InstrumentSegmentedControl(
                        selection: $settings.typeface,
                        options: AppTypeface.allCases.map { ($0.label, $0) })
                    .frame(width: 280)
                    .accessibilityLabel("Typeface")
                }

                SettingRow(label: "Text size", value: settings.textSize.label) {
                    InstrumentSegmentedControl(
                        selection: $settings.textSize,
                        options: AppTextSize.allCases.map { ($0.label, $0) })
                    .frame(width: 280)
                    .accessibilityLabel("Text size")
                }
            }

            SettingsCard(title: "Composer", icon: "text.cursor", footer: "The composer border stays a static hairline. Response style controls the agent’s final handoff.") {
                SettingToggle(label: "Show homepage suggestions", isOn: $settings.showHomeSuggestions)
                SettingRow(label: "Response style", value: settings.outputStyle.help) {
                    Picker("Response style", selection: $settings.outputStyle) {
                        ForEach(ProjectPolicy.OutputStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                }
            }

            SettingsCard(title: "Keyboard", icon: "keyboard", footer: "Shortcuts accept readable forms such as cmd+return. Esc always stops a running agent, and ⇧⌘M opens Model Manager.") {
                SettingToggle(label: "Enter sends", isOn: $settings.enterSends)
                Text(settings.enterSends
                     ? "Enter sends the message; Shift+Enter inserts a newline. The configured Send shortcut also works anywhere."
                     : "Enter inserts a newline. Use the configured Send shortcut to send.")
                    .font(.app(size: 11.5 ))
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
                SettingRow(label: "Updates") {
                    Button("Check for updates") {
                        if let url = URL(string: "https://thevamp.app/assistant") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(LFCapsuleButtonStyle())
                }
            }

        }
    }
}
