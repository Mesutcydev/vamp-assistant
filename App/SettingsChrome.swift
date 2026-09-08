import SwiftUI

// MARK: - Shared settings chrome

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    /// One silver faceplate per group: engraved technical heading inside,
    /// aligned rows beneath, helper text below the plate.
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Instrument.engraved)
                    Instrument.microLabel(title)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    content
                }
            }
            .padding(Chrome.cardHPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentFaceplate(radius: Radius.card, shadow: false)

            if let footer {
                Text(footer)
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One label-left / control-right row, uniform height and spacing.
struct SettingRow<Control: View>: View {
    let label: String
    var value: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        VampRow(label: label, value: value) { control }
    }
}

/// Boolean setting rendered as a SettingRow — label left, switch right — so
/// every toggle in the window aligns with the picker/stepper rows around it.
/// All settings toggles use the switch style (no mixed checkboxes).
struct SettingToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(label: label) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Compact shortcut editor. Users can type `cmd+shift+p` or the equivalent
/// readable spelling; the field normalizes it when editing finishes.
struct ShortcutEditor: View {
    let placeholder: String
    @Binding var value: String

    var body: some View {
        TextField(placeholder, text: $value)
            .textFieldStyle(.plain)
            .font(.app(size: 12, design: .monospaced))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .frame(width: 170, height: Chrome.buttonHeight)
            .background(Theme.surfaceInset,
                        in: RoundedRectangle(cornerRadius: Chrome.buttonRadius,
                                             style: .continuous))
            .onSubmit {
                value = ShortcutBinding(rawValue: value).canonicalValue
            }
            .help("Use cmd, shift, option, or control followed by a key, for example \(placeholder)")
    }
}

/// Accent palette picker rendered as color swatches. Each swatch shows the
/// palette's light-mode accent; selection draws an accent ring. Every swatch
/// carries a tooltip and VoiceOver label naming the palette.
struct PaletteSwatchPicker: View {
    @Binding var selection: AccentPalette

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(AccentPalette.allCases) { palette in
                swatch(for: palette)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func swatch(for palette: AccentPalette) -> some View {
        let isSelected = palette == selection
        Button {
            selection = palette
        } label: {
            ZStack {
                Circle()
                    .fill(swatchColor(palette))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Circle()
                            .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
                    )
                if isSelected {
                    // Intentionally NOT themed: the swatch beneath is always
                    // the palette's fixed light accent (see swatchColor), so
                    // this checkmark is white in both appearances by design.
                    Image(systemName: "checkmark")
                        .font(.app(size: 10, weight: .bold ))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .lfHoverLift()
        .help(palette.label)
        .accessibilityLabel("\(palette.label) palette")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Static preview color for the swatch — always the palette's light-mode
    /// accent so the picker itself stays readable in either appearance.
    private func swatchColor(_ palette: AccentPalette) -> Color {
        let hex = palette.hexes.accentLight
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

/// Settings page content wrapper: one vertical rhythm, no width or scroll
/// ownership. The Settings column owns centering/width; the Settings shell
/// owns scrolling. Keeping both here would double-center and double-scroll.
struct TabScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionGap) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Slim tinted banner for tab-level explanations — deliberately NOT a
/// SettingsCard, so a one-paragraph note doesn't read as a runt card next
/// to the content-rich cards around it.
struct InfoBanner: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.app(size: 12.5 ))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .vampOutlineCard(padding: EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
    }
}
