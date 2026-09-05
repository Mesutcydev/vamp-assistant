import SwiftUI

// MARK: - Settings

struct RemoteAppVersion: Equatable, Sendable {
    let version: String
    let build: String

    static let current: RemoteAppVersion = {
        let info = Bundle.main.infoDictionary
        return RemoteAppVersion(
            version: info?["CFBundleShortVersionString"] as? String ?? "—",
            build: info?["CFBundleVersion"] as? String ?? "—")
    }()
}

struct RemoteAppVersionFooter: View {
    @Environment(\.remoteAppearance) private var appearance
    let version: String
    let build: String

    var body: some View {
        Text("Version \(version) • Build \(build)",
             comment: "App version followed by the internal build number on the pairing screen.")
            .font(.caption.monospacedDigit())
            .foregroundStyle(BeetTheme.secondaryText(appearance))
            .accessibilityLabel("Vamp Assistant version \(version), build \(build)")
    }
}

/// One destination for everything that was scattered across the header, the
/// toolbar, and an overflow menu: theme, the paired Mac, and diagnostics.
///
/// It is a stock `Form`. The hand-built cards it replaced re-derived row
/// heights, separators, section labels and a switch that the platform draws
/// better — and drew them at four different corner radii.
struct RemoteSettingsSheet: View {
    @Bindable var store: RemoteStore
    var onSwitchComputer: () -> Void
    var onDiagnostics: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("remoteAppearanceSetting") private var appearanceSetting = RemoteAppearanceSetting.dark
    @AppStorage("remoteAccent") private var accent = AccentPalette.graphite
    @AppStorage(RemoteBackdropSetting.key) private var showsBackdrop = true
    @State private var showForgetMac = false

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                connectionSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background { RemoteBackdrop() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(
                "Forget this Mac?",
                isPresented: $showForgetMac,
                titleVisibility: .visible) {
                    Button("Forget this Mac", role: .destructive) {
                        Task {
                            if await store.revoke() {
                                dismiss()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This device is unpaired and its access token is deleted. You will need the pairing code from your Mac to connect again.")
                }
            .alert(store.errorTitle, isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "Unknown error")
            }
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearanceSetting) {
                ForEach(RemoteAppearanceSetting.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            AccentSwatchPicker(selection: $accent)
            Toggle("Background image", isOn: $showsBackdrop)
        } header: {
            Text("Appearance")
        } footer: {
            Text(showsBackdrop
                 ? "The engraved atmosphere sits behind every screen."
                 : "Screens draw on the plain system background instead.")
        }
        .remoteListRow()
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            LabeledContent {
                Text(store.isConnected ? store.connectionSubtitle : store.connectionLabel)
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.isConnected ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(store.activeComputerName)
                }
            }
            RemoteDisclosureRow(title: "Switch computer") {
                dismiss()
                onSwitchComputer()
            }
            RemoteDisclosureRow(title: "Control diagnostics") {
                dismiss()
                onDiagnostics()
            }
            Button("Forget this Mac", role: .destructive) { showForgetMac = true }
        } header: {
            Text("Mac")
        }
        .remoteListRow()
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: RemoteAppVersion.current.version)
                .monospacedDigit()
            LabeledContent("Build", value: RemoteAppVersion.current.build)
                .monospacedDigit()
        } header: {
            Text("About")
        } footer: {
            Text("Vamp Assistant for iPhone and iPad.")
        }
        .remoteListRow()
    }

}

/// Accent swatches. Each shows the palette's light-mode accent, which is a
/// fixed color in both appearances, so the row itself reads the same either way.
struct AccentSwatchPicker: View {
    @Binding var selection: AccentPalette

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AccentPalette.allCases) { palette in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    selection = palette
                } label: {
                    ZStack {
                        Circle()
                            .fill(color(palette))
                            .frame(width: 30, height: 30)
                        if palette == selection {
                            // Not themed: the swatch beneath is always the
                            // palette's fixed light accent, which carries white.
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .overlay {
                        Circle()
                            .strokeBorder(palette == selection ? Color.primary.opacity(0.55) : .clear,
                                          lineWidth: 2)
                            .frame(width: 38, height: 38)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(palette.label) accent")
                .accessibilityAddTraits(palette == selection ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    private func color(_ palette: AccentPalette) -> Color {
        let hex = palette.hexes.accentLight
        return Color(red: Double((hex >> 16) & 0xFF) / 255,
                     green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}
