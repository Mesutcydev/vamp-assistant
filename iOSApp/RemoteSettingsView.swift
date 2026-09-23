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

          RemoteConsoleSection(index: "03", title: "Connections") {
            VStack(spacing: 0) {
              NavigationLink {
                RemoteProvidersView(store: store)
              } label: {
                settingsRowLabel("API providers", symbol: "key.horizontal")
              }
              .buttonStyle(RemotePressButtonStyle())
            }
          }

          RemoteConsoleSection(index: "04", title: "About") {
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
      settingsRowLabel(title, symbol: symbol)
    }
    .buttonStyle(RemotePressButtonStyle())
  }

  private func settingsRowLabel(_ title: String, symbol: String) -> some View {
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
}

/// Provider metadata and connection state come from the paired Mac. The phone
/// never reads back credentials; saving sends the draft once to Mac Keychain.
private struct RemoteProvidersView: View {
  @Bindable var store: RemoteStore
  @State private var query = ""
  @State private var isLoading = false

  private var matchingProviders: [RemoteProviderOption] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return store.apiProviders.filter { provider in
      needle.isEmpty || provider.name.localizedCaseInsensitiveContains(needle)
        || provider.id.localizedCaseInsensitiveContains(needle)
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Add an API key to use that provider's models in iPhone and Mac conversations.")
          .font(.subheadline)
          .foregroundStyle(RemoteInstrument.secondaryInk)

        SearchField(text: $query, placeholder: "Find a provider")
          .accessibilityLabel("Find a provider")

        if let notice = store.providerNotice {
          VStack(alignment: .leading, spacing: 8) {
            Text(notice).font(.footnote).foregroundStyle(RemoteInstrument.danger)
            Button("Try again") { Task { await load() } }
          }
        } else if isLoading && store.apiProviders.isEmpty {
          ProgressView("Loading providers")
            .frame(maxWidth: .infinity, minHeight: 120)
        } else if matchingProviders.isEmpty {
          ContentUnavailableView.search(text: query)
            .frame(maxWidth: .infinity, minHeight: 200)
        }

        let connected = matchingProviders.filter(\.isReady)
        let builtIn = matchingProviders.filter { !$0.isReady && $0.kind == "builtIn" }
        let compatible = matchingProviders.filter { !$0.isReady && $0.kind == "compatible" }
        if !connected.isEmpty { providerSection("01", title: "Connected", providers: connected) }
        if !builtIn.isEmpty { providerSection("02", title: "Built-in", providers: builtIn) }
        if !compatible.isEmpty { providerSection("03", title: "Compatible services", providers: compatible) }

        Text("Keys are saved in your Mac's Keychain. Use a trusted connection when adding one from your phone.")
          .font(.footnote)
          .foregroundStyle(RemoteInstrument.secondaryInk)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 24)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
    .background { RemoteBackdrop() }
    .navigationTitle("API providers")
    .navigationBarTitleDisplayMode(.inline)
    .remoteNavigationChrome()
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
          .disabled(isLoading)
      }
    }
    .task { await load() }
  }

  private func providerSection(
    _ index: String, title: String, providers: [RemoteProviderOption]
  ) -> some View {
    RemoteConsoleSection(index: index, title: "\(title) · \(providers.count)") {
      VStack(spacing: 0) {
        ForEach(providers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { provider in
          NavigationLink {
            RemoteProviderDetailView(store: store, providerID: provider.id)
          } label: {
            HStack(spacing: 12) {
              Image(systemName: provider.isReady ? "checkmark.seal.fill" : "key.horizontal")
                .foregroundStyle(provider.isReady ? RemoteInstrument.green : RemoteInstrument.secondaryInk)
                .frame(width: 28)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 3) {
                Text(provider.name).font(.body.weight(.medium))
                Text(provider.needsMacSetup ? "Add a base URL" : provider.id == "custom" && !provider.configured ? "Base URL ready · key optional" : provider.kind == "compatible" ? "OpenAI-compatible" : "API key")
                  .font(.caption)
                  .foregroundStyle(RemoteInstrument.secondaryInk)
              }
              Spacer(minLength: 8)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(RemoteInstrument.secondaryInk)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { VampHairline() }
          }
          .buttonStyle(RemotePressButtonStyle())
        }
      }
    }
  }

  private func load() async {
    isLoading = true
    defer { isLoading = false }
    await store.loadAPIProviders()
  }
}

private struct RemoteProviderDetailView: View {
  @Bindable var store: RemoteStore
  let providerID: String

  @State private var keyDraft = ""
  @State private var baseURLDraft = ""
  @State private var modelDraft = ""
  @State private var isWorking = false
  @State private var statusMessage: String?
  @State private var showRemoveConfirmation = false

  private var provider: RemoteProviderOption? {
    store.apiProviders.first { $0.id == providerID }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let provider {
          RemoteConsoleSection(index: "01", title: "Connection") {
            RemoteMobileStatus(
              title: provider.isReady ? "READY" : "NOT CONNECTED",
              color: provider.isReady ? RemoteInstrument.green : RemoteInstrument.secondaryInk)
            if let baseURL = provider.baseURL {
              Text(baseURL).font(.caption.monospaced())
                .foregroundStyle(RemoteInstrument.secondaryInk)
                .textSelection(.enabled)
            }
            if providerID == "custom" {
              TextField("Base URL (https://…/v1)", text: $baseURLDraft)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Custom provider base URL")
              Button("Save base URL") {
                Task {
                  isWorking = true
                  statusMessage = nil
                  defer { isWorking = false }
                  if await store.saveCustomProviderURL(baseURLDraft) {
                    statusMessage = "Base URL saved on your Mac."
                  }
                }
              }
              .buttonStyle(.bordered)
              .disabled(isWorking || baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !provider.needsMacSetup {
              SecureField(provider.configured ? "New API key" : "API key", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .privacySensitive()
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(provider.configured ? "Replacement API key" : "API key")
              Button(provider.configured ? "Replace key" : "Save key") {
                Task {
                  isWorking = true
                  statusMessage = nil
                  defer { isWorking = false }
                  if await store.saveAPIKey(providerID: providerID, key: keyDraft) {
                    keyDraft = ""
                    statusMessage = "Key saved on your Mac. Choose a model or add its ID below."
                  }
                }
              }
              .buttonStyle(.borderedProminent)
              .disabled(isWorking || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if provider.configured {
              Button("Remove key", role: .destructive) { showRemoveConfirmation = true }
                .disabled(isWorking)
            }
            if isWorking { ProgressView("Updating provider") }
            if let statusMessage {
              Text(statusMessage).font(.footnote).foregroundStyle(RemoteInstrument.green)
            }
          }
          if provider.isReady {
            RemoteConsoleSection(index: "02", title: "Add model") {
              Text("Use a model ID from this provider when it does not appear in the picker.")
                .font(.footnote)
                .foregroundStyle(RemoteInstrument.secondaryInk)
              TextField("Model ID", text: $modelDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
              Button("Add model") {
                Task {
                  isWorking = true
                  statusMessage = nil
                  defer { isWorking = false }
                  if await store.addProviderModel(providerID: providerID, modelID: modelDraft) {
                    modelDraft = ""
                    statusMessage = "Model added to the picker."
                  }
                }
              }
              .buttonStyle(.bordered)
              .disabled(isWorking || modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
        } else {
          ContentUnavailableView("Provider unavailable", systemImage: "key.slash")
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 24)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
    .background { RemoteBackdrop() }
    .navigationTitle(provider?.name ?? "API provider")
    .navigationBarTitleDisplayMode(.inline)
    .remoteNavigationChrome()
    .task(id: provider?.baseURL) {
      if providerID == "custom", baseURLDraft.isEmpty {
        baseURLDraft = provider?.baseURL ?? ""
      }
    }
    .confirmationDialog("Remove this API key from your Mac?", isPresented: $showRemoveConfirmation) {
      Button("Remove key", role: .destructive) {
        Task {
          isWorking = true
          statusMessage = nil
          defer { isWorking = false }
          if await store.removeAPIKey(providerID: providerID) {
            keyDraft = ""
            statusMessage = "Key removed from your Mac."
          }
        }
      }
    } message: {
      Text("This provider's models will no longer be available until you add another key.")
    }
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
