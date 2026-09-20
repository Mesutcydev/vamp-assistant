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
    Text(
      "Version \(version) • Build \(build)",
      comment: "App version followed by the internal build number on the pairing screen."
    )
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
  @AppStorage("remoteAppearanceSetting") private var appearanceSetting = RemoteAppearanceSetting
    .dark
  @AppStorage("remoteAccent") private var accent = AccentPalette.graphite
  @State private var showForgetMac = false
  @State private var showOfflineForget = false
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          RemoteConsoleSection(index: "01", title: "Appearance") {
            VampMicroLabel(title: "THEME")
            RemoteInstrumentSegments(
              selection: $appearanceSetting,
              options: RemoteAppearanceSetting.allCases.map { ($0.label, $0) }
            )
            .accessibilityLabel("Appearance")

            VStack(alignment: .leading, spacing: 8) {
              VampMicroLabel(title: "ACCENT")
              InstrumentAccentBank(
                selection: $accent,
                palettes: AccentPalette.allCases,
                labels: AccentPalette.allCases.map { "\($0.label) accent" },
                colors: AccentPalette.allCases.map { palette in
                  let hex = palette.hexes.accentLight
                  return Color(
                    red: Double((hex >> 16) & 0xFF) / 255,
                    green: Double((hex >> 8) & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255)
                })
            }

            Text("Controls appearance and signal accents.")
              .font(.footnote)
              .foregroundStyle(RemoteInstrument.secondaryInk)
          }

          RemoteConsoleSection(index: "02", title: "Paired Mac") {
            VStack(alignment: .leading, spacing: 6) {
              RemoteMobileStatus(
                title: store.isConnected ? "MAC CONNECTED" : "MAC OFFLINE",
                color: store.isConnected ? RemoteInstrument.green : RemoteInstrument.secondaryInk)
              Text(store.activeComputerName)
                .font(.body.weight(.medium)).textSelection(.enabled)
              Text(store.isConnected ? store.connectionSubtitle : store.connectionLabel)
                .font(.caption.monospaced())
                .foregroundStyle(RemoteInstrument.secondaryInk)
            }
            .padding(.vertical, 10)
            VStack(spacing: 0) {
              settingsRow("Switch computer", symbol: "desktopcomputer.and.macbook") {
                dismiss()
                onSwitchComputer()
              }
              settingsRow("Control diagnostics", symbol: "stethoscope") {
                dismiss()
                onDiagnostics()
              }
              Button(role: .destructive) {
                showForgetMac = true
              } label: {
                Text("Forget this Mac")
                  .font(.body).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                  .contentShape(Rectangle())
              }
              .buttonStyle(RemotePressButtonStyle())
              .foregroundStyle(RemoteInstrument.danger)
            }
          }

          RemoteConsoleSection(index: "03", title: "About") {
            VStack(spacing: 0) {
              RemoteSettingValue(title: "Product", value: "Vamp Assistant")
              RemoteSettingValue(title: "Platform", value: "iPhone and iPad")
              RemoteSettingValue(title: "Version", value: RemoteAppVersion.current.version)
              RemoteSettingValue(title: "Build", value: RemoteAppVersion.current.build)
            }
          }

        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 20)
        .padding(.vertical, 28)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
      }
      .scrollContentBackground(.hidden)
      .background { RemoteBackdrop() }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .remoteNavigationChrome()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
          .vampUtilityAction()
      }
      .toolbarBackground(BeetTheme.background(appearance), for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .confirmationDialog(
        "Forget this Mac?",
        isPresented: $showForgetMac,
        titleVisibility: .visible
      ) {
        Button("Forget this Mac", role: .destructive) {
          Task {
            switch await store.revoke() {
            case .revoked:
              dismiss()
            case .unreachable:
              showOfflineForget = true
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "This device is unpaired and its access token is deleted. You will need the pairing code from your Mac to connect again."
        )
      }
      .alert("Mac not reachable", isPresented: $showOfflineForget) {
        Button("Forget Locally", role: .destructive) {
          store.forgetSavedMac()
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "Vamp Assistant couldn't reach this Mac to revoke the token. You can still forget it on this device; revoke it from the Mac's Remote settings to invalidate it there."
        )
      }
      .alert(
        store.errorTitle,
        isPresented: Binding(
          get: { store.errorMessage != nil },
          set: { if !$0 { store.errorMessage = nil } }
        )
      ) {
        Button("OK") { store.errorMessage = nil }
      } message: {
        Text(store.errorMessage ?? "Unknown error")
      }
    }
    .presentationCornerRadius(12)
  }

  private func settingsRow(
    _ title: String,
    symbol: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: symbol)
          .font(.system(size: 19, weight: .medium))
          .frame(width: 28).accessibilityHidden(true)
        Text(title).font(.body).fixedSize(
          horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(RemoteInstrument.secondaryInk)
      }
      .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
      .contentShape(Rectangle())
      .overlay(alignment: .bottom) { VampHairline() }
    }
    .buttonStyle(RemotePressButtonStyle())
  }
}

/// Metadata stacks at accessibility sizes without squeezing either column.
private struct RemoteSettingValue: View {
  let title: String
  let value: String
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(spacing: 12))
    layout {
      Text(title.uppercased()).font(.caption.monospaced()).foregroundStyle(
        RemoteInstrument.secondaryInk)
      if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
      Text(verbatim: value).font(.subheadline.weight(.medium)).foregroundStyle(RemoteInstrument.ink)
        .monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 44)
    .padding(.vertical, 4)
    .overlay(alignment: .bottom) { VampHairline() }
    .accessibilityElement(children: .combine)
  }
}
