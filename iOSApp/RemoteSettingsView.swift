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

struct RemoteAppVersionCard: View {
    @Environment(\.remoteAppearance) private var appearance
    let version: String
    let build: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteSectionLabel(title: "ABOUT")
            HStack(spacing: 12) {
                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(BeetTheme.accentBright)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Vamp Assistant")
                        .font(.body.weight(.semibold))
                    Text("iPhone and iPad companion")
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack {
                Text("Version")
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                Spacer()
                Text(verbatim: version)
                    .font(.body.monospacedDigit())
            }
            HStack {
                Text("Build")
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                Spacer()
                Text(verbatim: build)
                    .font(.body.monospacedDigit())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }
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
struct RemoteSettingsSheet: View {
    @Bindable var store: RemoteStore
    var onSwitchComputer: () -> Void
    var onDiagnostics: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @AppStorage("remoteAppearanceSetting") private var appearanceSetting = RemoteAppearanceSetting.dark
    @AppStorage("remoteAccent") private var accent = AccentPalette.graphite
    @State private var showForgetMac = false

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        appearanceSection
                        connectionSection
                        RemoteAppVersionCard(
                            version: RemoteAppVersion.current.version,
                            build: RemoteAppVersion.current.build)
                    }
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
        VStack(alignment: .leading, spacing: 12) {
            RemoteSectionLabel(title: "APPEARANCE")
            Picker("Appearance", selection: $appearanceSetting) {
                ForEach(RemoteAppearanceSetting.allCases) { option in
                    Label(option.label, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text("ACCENT")
                .font(.caption2.bold())
                .tracking(0.8)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
                .padding(.top, 4)
            AccentSwatchPicker(selection: $accent)
            Text(accent.label)
                .font(.caption)
                .foregroundStyle(BeetTheme.secondaryText(appearance))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }

    // MARK: Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteSectionLabel(title: "MAC")
            HStack(spacing: 10) {
                Circle()
                    .fill(store.isConnected ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeComputerName).font(.body.weight(.semibold))
                    Text(store.isConnected ? store.connectionSubtitle : store.connectionLabel)
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
            }

            settingsRow("Switch computer", symbol: "desktopcomputer.and.macbook") {
                dismiss()
                onSwitchComputer()
            }
            settingsRow("Control diagnostics", symbol: "stethoscope") {
                dismiss()
                onDiagnostics()
            }
            settingsRow("Forget this Mac", symbol: "iphone.slash", destructive: true) {
                showForgetMac = true
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(BeetTheme.line(appearance)) }
    }

    private func settingsRow(
        _ title: String,
        symbol: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .foregroundStyle(destructive ? Color.red : BeetTheme.accentBright)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                Spacer(minLength: 0)
                if !destructive {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
