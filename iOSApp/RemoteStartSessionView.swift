import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteStartModeRow: View {
  @Binding var mode: RemoteSessionMode
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    RemoteConfigurationRow(title: "Works in") {
      Menu {
        Picker("Works in", selection: $mode) {
          ForEach(RemoteSessionMode.allCases) { option in
            Label(option.title, systemImage: option.symbol).tag(option)
          }
        }
      } label: {
        HStack(spacing: 8) {
          Rectangle().fill(RemoteInstrument.orange).frame(width: 2, height: 12)
          Label(mode.title, systemImage: mode.symbol)
          Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.subheadline.weight(.medium)).foregroundStyle(.white)
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(RemoteInstrument.darkInsert, in: RoundedRectangle(cornerRadius: 7))
      }
      .accessibilityLabel("Works in, \(mode.title)")
    }
  }
}

struct RemoteStartNavigationRow<Destination: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @ViewBuilder let destination: () -> Destination

  var body: some View {
    NavigationLink {
      destination()
    } label: {
      RemoteConfigurationRow(title: title) {
        HStack(spacing: 8) {
          Text(subtitle)
          Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }
      }
    }
    .buttonStyle(RemotePressButtonStyle())
  }
}

/// Two independent run permissions presented as one small hardware bank.
/// Native switch rows let their labels compress inside the disclosure column;
/// equal-width keys keep both names and states readable on narrow phones, then
/// stack at accessibility sizes without changing either setting's meaning.
struct RemoteAdvancedAccessBank: View {
  @Binding var autoMode: Bool
  @Binding var fullAccess: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    let layout = dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 1))
      : AnyLayout(HStackLayout(spacing: 1))

    return VStack(alignment: .leading, spacing: 6) {
      layout {
        // Both flags reach the Mac's permission gate as `fullAccess || autoMode`
        // (AgentSessionController.effectiveFullAccess), so Auto mode on its own
        // already runs uninterrupted. The hints say so rather than implying that
        // Full Access off still means "you will be asked".
        accessKey(title: "Auto mode", isOn: $autoMode,
                  hint: "Runs the task without pausing for your approval.")
        accessKey(title: "Full access", isOn: $fullAccess,
                  hint: "Runs without approval prompts, including file writes and commands.")
      }
      .padding(3)
      .background(
        RemoteInstrument.housing,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(RemoteInstrument.chassisEdge, lineWidth: 1)
          .allowsHitTesting(false)
      }

      // Two independent-looking keys implied a graduated model, but the Mac
      // gates on `fullAccess || autoMode`, so Auto mode alone already runs
      // uninterrupted — and Auto mode is on by default. State the effective
      // policy rather than letting "FULL ACCESS / OFF" imply restraint.
      Text(autoMode || fullAccess
           ? "This run skips approval prompts."
           : "Your Mac's approval settings apply.")
        .font(.caption2)
        .foregroundStyle(autoMode || fullAccess
                         ? RemoteInstrument.orange : RemoteInstrument.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Without this the line sits 12pt off the next row's micro-label and
        // the two read as one block.
        .padding(.bottom, 6)
    }
  }

  private func accessKey(title: String, isOn: Binding<Bool>, hint: String) -> some View {
    Button {
      UISelectionFeedbackGenerator().selectionChanged()
      isOn.wrappedValue.toggle()
    } label: {
      HStack(spacing: 9) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title.uppercased())
            .font(.caption.monospaced().weight(.semibold))
            .tracking(0.45)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
          Text(isOn.wrappedValue ? "ON" : "OFF")
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(isOn.wrappedValue ? RemoteInstrument.orange : RemoteInstrument.secondaryInk)
        }
        Spacer(minLength: 4)
        InstrumentIndicator(
          color: RemoteInstrument.orange,
          visible: isOn.wrappedValue,
          width: 14,
          height: 2
        )
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 58 : 50)
      .contentShape(Rectangle())
    }
    .buttonStyle(RemoteKeyButtonStyle(isSelected: isOn.wrappedValue))
    .accessibilityLabel(title)
    .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    // ponytail: it behaves as a switch, so announce it as one. `.isSelected`
    // made VoiceOver read a two-state control as a plain selected button.
    .accessibilityAddTraits(.isToggle)
    .accessibilityHint(hint)
  }
}

struct StartSessionSheet: View {
  @Bindable var store: RemoteStore
  let initialBotID: String
  let onStarted: (UUID) -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.remoteAppearance) private var appearance
  @State private var source = "local"
  @State private var selectedModelID = ""
  @State private var selectedReasoningEffort: String?
  @State private var showModelPicker = false
  @State private var prompt = ""
  @State private var botComputers: [RemoteBotComputer] = []
  @State private var selectedBotComputerID: UUID?
  @State private var botComputerBusyID: UUID?
  @State private var consoleComputer: RemoteBotComputer?
  @State private var keyProviderID = "openAI"
  @State private var keyDraft = ""
  @State private var isSavingKey = false
  @State private var keyMessage: String?
  @State private var selectedBotID = ""
  @State private var sessionMode: RemoteSessionMode = .chat
  @State private var autoMode = true
  @State private var fullAccess = false
  @State private var isLoadingModels = false
  @State private var isStarting = false
  @State private var selectedWorkspacePath = ""
  @State private var newFolderName = ""
  @State private var showNewFolder = false
  @State private var folderPathDraft = ""
  @State private var showPathEntry = false
  @State private var showAdvanced = false
  // Start choices follow the Mac's restored-project behavior without
  // becoming part of the remote protocol or a persisted prompt draft.
  @AppStorage("remoteStart.sessionMode") private var savedSessionModeRaw =
    RemoteSessionMode.chat.rawValue
  @AppStorage("remoteStart.source") private var savedSource = "local"
  @AppStorage("remoteStart.modelID") private var savedModelID = ""
  @AppStorage("remoteStart.reasoningEffort") private var savedReasoningEffort = ""
  @AppStorage("remoteStart.workspacePath") private var savedWorkspacePath = ""
  @FocusState private var taskFocused: Bool
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(
    store: RemoteStore, initialBotID: String, initialPrompt: String = "",
    showAdvanced: Bool = false,
    onStarted: @escaping (UUID) -> Void
  ) {
    self.store = store
    self.initialBotID = initialBotID
    self.onStarted = onStarted
    _prompt = State(initialValue: initialPrompt)
    _showAdvanced = State(initialValue: showAdvanced)
  }

  private var codeFolderMissing: Bool {
    sessionMode == .code
      && selectedBotComputerID == nil
      && (selectedWorkspacePath.isEmpty || !store.workspacesSupported)
  }

  private var canStart: Bool {
    store.isConnected
      && !selectedModelID.isEmpty
      && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isStarting
      && !codeFolderMissing
  }

  private var botProfile: RemoteBotProfile {
    RemoteBotProfile.profile(
      id: selectedBotID.isEmpty ? RemoteBotProfile.general.id : selectedBotID)
  }
  private var restoredSessionMode: RemoteSessionMode {
    RemoteSessionMode(rawValue: savedSessionModeRaw) ?? .chat
  }
  private var restoredReasoningEffort: String? {
    savedReasoningEffort.isEmpty ? nil : savedReasoningEffort
  }
  private var models: [RemoteStartModelOption] { store.startModels.filter { $0.source == source } }
  private var selectedWorkspaceTitle: String {
    guard !selectedWorkspacePath.isEmpty else { return "Choose a folder" }
    return store.workspaces.first(where: { $0.path == selectedWorkspacePath })?.name
      ?? selectedWorkspacePath
  }
  private var groupedAPIModels: [(detail: String, models: [RemoteStartModelOption])] {
    let groups = Dictionary(grouping: models, by: \.detail)
    return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { key in
      (key, groups[key]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
  }
  private var sourceIcon: String {
    switch source {
    case "chatgpt": "person.crop.circle"
    case "api": "cloud"
    default: "cpu"
    }
  }
  private var emptyModelsTitle: String {
    switch source {
    case "chatgpt": "No ChatGPT models"
    case "api": "No API models"
    default: "No local models"
    }
  }
  private var emptyModelsDescription: String {
    switch source {
    case "chatgpt": "Sign in with ChatGPT on your Mac to use GPT-6 Astra, then refresh."
    case "api": "Configure an API provider on your Mac first."
    default: "Download a model on your Mac first."
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if !store.isConnected {
            Section {
              RemoteReconnectBanner(store: store)
                .listRowInsets(EdgeInsets())
            }
          }

          RemoteConsoleSection(index: "01", title: "Task") {
            // ponytail: a `prompt` truncates to one line on a vertical-axis
            // field, so at accessibility sizes this read "What should i…".
            // The placeholder is a sibling in the ZStack rather than an
            // overlay so it contributes height — 116 is a floor, so the box
            // grows to fit the wrapped text instead of clipping it.
            ZStack(alignment: .topLeading) {
              if prompt.isEmpty {
                Text("What should it work on?")
                  .font(.body)
                  .foregroundStyle(RemoteInstrument.secondaryInk)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
              TextField("", text: $prompt, axis: .vertical)
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 3 : 6))
                .font(.body)
                .focused($taskFocused)
                .accessibilityLabel("Task")
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .remoteRecess(focused: taskFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: taskFocused)
            suggestionBank
          }

          if isLoadingModels || store.backgroundNotice != nil {
            Section {
              HStack(spacing: 10) {
                if isLoadingModels {
                  ProgressView()
                } else {
                  Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(RemoteInstrument.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                  Text(isLoadingModels ? "Loading models…" : "Model catalog unavailable")
                    .font(.subheadline.weight(.semibold))
                  if let notice = store.backgroundNotice, !isLoadingModels {
                    Text(notice)
                      .font(.footnote)
                      .foregroundStyle(RemoteInstrument.secondaryInk)
                  }
                }
                Spacer()
                if !isLoadingModels {
                  Button("Retry") { loadModels() }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                }
              }
            }
          }

          RemoteConsoleSection(index: "02", title: "Setup") {
            VStack(spacing: 0) {
              RemoteStartModeRow(mode: $sessionMode)
              RemoteStartNavigationRow(
                title: "Bot",
                subtitle: botProfile.name,
                symbol: "person.crop.circle"
              ) {
                RemoteBotChooser(selectedBotID: $selectedBotID)
                  .navigationTitle("Bot")
              }
              Button {
                showModelPicker = true
              } label: {
                RemoteConfigurationRow(title: "Model") {
                  HStack(spacing: 8) {
                    Text(selectedModelName)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                  }
                }
              }
              .buttonStyle(RemotePressButtonStyle())
              if sessionMode == .code {
                RemoteStartNavigationRow(
                  title: "Project folder",
                  subtitle: selectedWorkspaceTitle,
                  symbol: "folder"
                ) {
                  workspaceSection
                    .navigationTitle("Project folder")
                }
              }
            }
          }

          RemoteConsoleSection(index: "03", title: "More") {
            DisclosureGroup("Advanced setup", isExpanded: $showAdvanced) {
              RemoteInstrumentSegments(
                selection: $source,
                options: RemoteModelPickerSheet.sources.map {
                  (RemoteModelPickerSheet.sourceLabel($0), $0)
                })
              RemoteAdvancedAccessBank(autoMode: $autoMode, fullAccess: $fullAccess)
              botComputerSection
              apiKeySection
              if let selected = models.first(where: { $0.id == selectedModelID }),
                let efforts = selected.reasoningEfforts, !efforts.isEmpty
              {
                RemoteReasoningSelector(
                  modelName: selected.name,
                  efforts: efforts,
                  defaultEffort: selected.defaultReasoningEffort,
                  selection: $selectedReasoningEffort)
              }
            }
            .font(.subheadline.weight(.medium)).tint(RemoteInstrument.ink)
            .padding(.vertical, 10)
          }
        }
        .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 20)
        .padding(.vertical, 28)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
      }
      .scrollContentBackground(.hidden)
      .scrollDismissesKeyboard(.interactively)
      .background(BeetTheme.background(appearance))
      .safeAreaInset(edge: .bottom, spacing: 0) {
        startDeck
      }
      .navigationTitle("New session")
      .navigationBarTitleDisplayMode(.inline)
      .remoteNavigationChrome()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          .vampUtilityAction()
      }
      .toolbarBackground(BeetTheme.background(appearance), for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .sheet(item: $consoleComputer) { computer in
        RemoteBotConsoleView(store: store, computer: computer)
      }
      .sheet(isPresented: $showModelPicker) {
        RemoteModelPickerSheet(
          models: store.startModels,
          source: $source,
          selectedModelID: $selectedModelID,
          onSelect: { selectedReasoningEffort = $0.defaultReasoningEffort },
          onRefresh: { await store.loadStartModels() }
        )
        .environment(\.remoteAppearance, appearance)
      }
      .task {
        selectedBotID = initialBotID
        source = savedSource
        selectedModelID = savedModelID
        selectedReasoningEffort = restoredReasoningEffort
        sessionMode = restoredSessionMode
        selectedWorkspacePath = savedWorkspacePath
        async let models: Void = loadModels()
        async let computers: Void = loadBotComputers()
        async let folders: Void = store.loadWorkspaces()
        _ = await (models, computers, folders)
        attachMatchingBotComputer()
        selectFirstModel()
        if store.workspacesSupported {
          if !store.workspaces.contains(where: { $0.path == selectedWorkspacePath }) {
            selectedWorkspacePath =
              store.workspaces.first(where: { $0.isCurrent == true })?.path
              ?? store.workspaces.first?.path
              ?? ""
          }
        } else {
          selectedWorkspacePath = ""
        }
        savedWorkspacePath = selectedWorkspacePath
      }
      .onChange(of: source) { _, newValue in
        savedSource = newValue
        selectFirstModel()
      }
      .onChange(of: selectedModelID) { _, newValue in
        savedModelID = newValue
      }
      .onChange(of: selectedReasoningEffort) { _, newValue in
        savedReasoningEffort = newValue ?? ""
      }
      .onChange(of: selectedWorkspacePath) { _, newValue in
        savedWorkspacePath = newValue
      }
      .onChange(of: sessionMode) { _, mode in
        savedSessionModeRaw = mode.rawValue
        handleModeChange(mode)
      }
      .onChange(of: selectedBotID) { _, _ in attachMatchingBotComputer() }
      .alert("New folder on Mac", isPresented: $showNewFolder) {
        TextField("Folder name", text: $newFolderName)
        Button("Cancel", role: .cancel) { newFolderName = "" }
        Button("Create") { createFolder() }
      } message: {
        Text(
          store.workspaceCreateParent.map { "Created inside \($0)." }
            ?? "Created in the app’s Documents folder on your Mac.")
      }
      .alert("Open a folder path", isPresented: $showPathEntry) {
        TextField("~/Developer/my-app", text: $folderPathDraft)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Button("Cancel", role: .cancel) { folderPathDraft = "" }
        Button("Open") { openFolderPath() }
      } message: {
        Text("The folder must already exist inside your Mac home directory.")
      }
      .keyboardDismissToolbar()
    }
  }

  private var suggestionBank: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    return layout {
      ForEach(Array(botProfile.starters.enumerated()), id: \.offset) { index, starter in
        if index > 0 {
          if dynamicTypeSize.isAccessibilitySize {
            VampHairline()
          } else {
            Rectangle().fill(RemoteInstrument.seam).frame(width: 0.75, height: 28)
          }
        }
        Button {
          prompt = starter
          taskFocused = true
          UISelectionFeedbackGenerator().selectionChanged()
        } label: {
          Text(starter).font(.caption.monospaced().weight(.medium))
            // ponytail: side-by-side chips hold different label lengths, so one
            // wrapped to two lines while its neighbours sat centred on one.
            // Reserving both lines aligns every chip; stacked (accessibility)
            // layout has no neighbour to align to, so it does not reserve.
            .lineLimit(2, reservesSpace: !dynamicTypeSize.isAccessibilitySize)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(RemotePressButtonStyle())
        .accessibilityHint("Fills the task field with this starter.")
      }
    }
    .foregroundStyle(RemoteInstrument.ink).remoteFaceplate(radius: 8)
  }

  private var startDeck: some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 12))
    return layout {
      RemoteMobileStatus(
        title: !store.isConnected
          ? "MAC OFFLINE" : isStarting ? "STARTING" : canStart ? "READY" : "CONFIGURATION",
        color: canStart ? RemoteInstrument.green : RemoteInstrument.secondaryInk,
        isActive: isStarting)
      if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
      Button {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        start()
      } label: {
        HStack(spacing: 8) {
          if isStarting { ProgressView() }
          Text(isStarting ? "Starting…" : "Start").font(.subheadline.weight(.semibold))
          Image(systemName: "arrow.up.right").font(.caption)
        }.frame(minWidth: 90, minHeight: 44)
      }.buttonStyle(RemotePrimaryButtonStyle()).disabled(!canStart)
        .accessibilityLabel("Start session")
    }
    .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 20).padding(.vertical, 10)
    .frame(maxWidth: 720).frame(maxWidth: .infinity)
    .background(RemoteInstrument.header)
    .overlay(alignment: .top) { VampHairline() }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: canStart)
  }

  private var selectedModelName: String {
    guard let selected = store.startModels.first(where: { $0.id == selectedModelID }) else {
      return models.isEmpty ? emptyModelsTitle : "Choose a model"
    }
    return selected.name
  }

  private func loadModels() async {
    isLoadingModels = true
    await store.loadStartModels()
    isLoadingModels = false
    selectFirstModel()
  }

  private func loadModels() {
    Task { await loadModels() }
  }

  private func handleModeChange(_ mode: RemoteSessionMode) {
    guard mode == .chat else { return }
    selectedBotComputerID = nil
  }

  private func selectFirstModel() {
    if let selected = models.first(where: { $0.id == selectedModelID }) {
      selectedReasoningEffort = selected.defaultReasoningEffort
      return
    }

    let first: RemoteStartModelOption?
    switch source {
    case "chatgpt":
      first = models.first(where: \.isLatest) ?? models.first
    case "api":
      first =
        groupedAPIModels.first?.models.first(where: \.isLatest)
        ?? groupedAPIModels.first?.models.first
    default:
      first = models.first
    }
    selectedModelID = first?.id ?? ""
    selectedReasoningEffort = first?.defaultReasoningEffort
  }

  @ViewBuilder
  private var workspaceSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("PROJECT FOLDER").font(.caption2.bold()).tracking(0.8)
        Spacer()
        if selectedBotComputerID != nil {
          Text("Bot computer")
            .font(.caption)
        }
      }.foregroundStyle(BeetTheme.secondaryText(appearance))
      if !store.workspacesSupported {
        Text("Update Vamp Assistant on your Mac to open or create a project folder from here.")
          .font(.subheadline)
          .foregroundStyle(BeetTheme.secondaryText(appearance))
      } else if selectedBotComputerID != nil {
        Text("This session uses the selected bot computer’s workspace and private browser.")
          .font(.subheadline)
          .foregroundStyle(BeetTheme.secondaryText(appearance))
      } else {
        if store.workspaces.isEmpty {
          Text("No recent folders yet. Create one or open a path on your Mac.")
            .font(.subheadline)
            .foregroundStyle(BeetTheme.secondaryText(appearance))
        } else {
          VStack(spacing: 0) {
            ForEach(store.workspaces) { folder in
              Button {
                selectedWorkspacePath = folder.path
              } label: {
                HStack(spacing: 12) {
                  Image(
                    systemName: selectedWorkspacePath == folder.path
                      ? "checkmark.circle.fill" : "folder.fill"
                  )
                  .foregroundStyle(
                    selectedWorkspacePath == folder.path
                      ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance)
                  )
                  .frame(width: 24)
                  .accessibilityHidden(true)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name).font(.body.weight(.semibold))
                    Text(folder.path).font(.caption).foregroundStyle(
                      BeetTheme.secondaryText(appearance)
                    ).lineLimit(1)
                  }
                  Spacer()
                }.padding(13).contentShape(Rectangle())
                  .accessibilityAddTraits(selectedWorkspacePath == folder.path ? .isSelected : [])
              }.buttonStyle(.plain)
              if folder.path != store.workspaces.last?.path {
                Divider().overlay(BeetTheme.line(appearance))
              }
            }
          }
          .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 10))
          .overlay { RoundedRectangle(cornerRadius: 10).stroke(BeetTheme.line(appearance)) }
        }
        HStack(spacing: 10) {
          Button {
            showNewFolder = true
          } label: {
            Label("New folder", systemImage: "folder.badge.plus")
              .font(.subheadline.weight(.semibold))
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(RemoteSecondaryButtonStyle())
          Button {
            showPathEntry = true
          } label: {
            Label("Path", systemImage: "text.alignleft")
              .font(.subheadline.weight(.semibold))
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(RemoteSecondaryButtonStyle())
        }
      }
    }
  }

  private func createFolder() {
    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    newFolderName = ""
    guard !name.isEmpty else { return }
    Task {
      if let created = await store.createWorkspace(name: name) {
        selectedWorkspacePath = created.path
      }
    }
  }

  private func openFolderPath() {
    let path = folderPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    folderPathDraft = ""
    guard !path.isEmpty else { return }
    Task {
      if let opened = await store.openWorkspace(path: path) {
        selectedWorkspacePath = opened.path
      }
    }
  }

  @ViewBuilder
  private var botComputerSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("BOT COMPUTER").font(.caption2.bold()).tracking(0.8)
        Spacer()
        Text(
          botComputers.isEmpty
            ? "None prepared on Mac"
            : (selectedBotComputerID == nil ? "Optional — tap to attach" : "Attached")
        )
        .font(.caption)
      }.foregroundStyle(BeetTheme.secondaryText(appearance))
      if !botComputers.isEmpty {
        VStack(spacing: 0) {
          ForEach(botComputers) { computer in
            HStack(spacing: 11) {
              Button {
                guard canAttachBotComputer(computer) else { return }
                selectedBotComputerID = selectedBotComputerID == computer.id ? nil : computer.id
                if selectedBotComputerID != nil { sessionMode = .code }
              } label: {
                HStack(spacing: 11) {
                  Image(
                    systemName: selectedBotComputerID == computer.id
                      ? "checkmark.circle.fill" : "square.stack.3d.up.fill"
                  )
                  .foregroundStyle(
                    selectedBotComputerID == computer.id
                      ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                  VStack(alignment: .leading, spacing: 3) {
                    Text(displayName(for: computer)).font(.body.weight(.semibold))
                    Text(botComputerSubtitle(computer))
                      .font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
                  }
                  Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(!canAttachBotComputer(computer))
              .accessibilityLabel(
                selectedBotComputerID == computer.id
                  ? "Detach \(displayName(for: computer))" : "Attach \(displayName(for: computer))"
              )
              .accessibilityValue(botComputerSubtitle(computer))
              .accessibilityAddTraits(selectedBotComputerID == computer.id ? .isSelected : [])
              // A bot computer has no screen to stream; its console is the shell,
              // the workspace, and the output.
              Button {
                consoleComputer = computer
              } label: {
                Image(systemName: "terminal")
              }
              .buttonStyle(RemoteSecondaryButtonStyle())
              .accessibilityLabel("Open \(displayName(for: computer)) console")
              if computer.state == "running" {
                Button(botComputerBusyID == computer.id ? "Stopping…" : "Stop") {
                  stopBotComputer(computer)
                }
                .buttonStyle(RemoteSecondaryButtonStyle())
                .disabled(botComputerBusyID != nil)
              } else if computer.backend != "isolatedWorkspace" {
                Button(botComputerBusyID == computer.id ? "Starting…" : "Start") {
                  startBotComputer(computer)
                }
                .buttonStyle(RemotePrimaryButtonStyle()).tint(BeetTheme.accentBright)
                .disabled(botComputerBusyID != nil)
              }
            }
            .padding(13)
            if computer.id != botComputers.last?.id {
              Divider().overlay(BeetTheme.line(appearance))
            }
          }
        }
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(BeetTheme.line(appearance)) }
      }
      if let profileID = RemoteBotProfile.resolvedID(selectedBotID),
        !botComputers.contains(where: { $0.profileID == profileID })
      {
        Button {
          prepareBotComputer(profileID: profileID)
        } label: {
          Label("Create \(botProfile.name) computer on Mac", systemImage: "plus")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(RemoteSecondaryButtonStyle())
        .disabled(botComputerBusyID != nil || !store.isConnected)
      } else if botComputers.isEmpty {
        Button {
          prepareBotComputer(profileID: nil)
        } label: {
          Label("Prepare bot computers on Mac", systemImage: "plus")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(RemoteSecondaryButtonStyle())
        .disabled(botComputerBusyID != nil || !store.isConnected)
      }
    }
  }

  private func displayName(for computer: RemoteBotComputer) -> String {
    computer.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(
      "Beet") == .orderedSame
      ? "Assistant computer"
      : computer.name
  }

  private func canAttachBotComputer(_ computer: RemoteBotComputer) -> Bool {
    computer.state == "running" || computer.backend == "isolatedWorkspace"
  }

  private func botComputerSubtitle(_ computer: RemoteBotComputer) -> String {
    let backend: String
    switch computer.backend {
    case "appleContainer": backend = "Linux micro-VM"
    case "isolatedWorkspace": backend = "Private workspace"
    default: backend = computer.backend
    }
    return computer.state.capitalized + " · " + backend + " · private browser"
  }

  private func attachMatchingBotComputer() {
    guard let profileID = RemoteBotProfile.resolvedID(selectedBotID) else { return }
    if let match = botComputers.first(where: {
      $0.profileID == profileID && canAttachBotComputer($0)
    }) {
      selectedBotComputerID = match.id
      sessionMode = .code
    }
  }

  private func prepareBotComputer(profileID: String?) {
    botComputerBusyID = UUID()
    Task {
      let computers = await store.prepareBotComputers(profileID: profileID)
      if !computers.isEmpty {
        botComputers = computers
        attachMatchingBotComputer()
      } else {
        await loadBotComputers()
      }
      botComputerBusyID = nil
    }
  }

  private func loadBotComputers() async {
    if let envelope = await store.botComputers() {
      botComputers = envelope.computers
      if let selected = selectedBotComputerID,
        !envelope.computers.contains(where: {
          $0.id == selected && ($0.state == "running" || $0.backend == "isolatedWorkspace")
        })
      {
        selectedBotComputerID = nil
      }
    }
  }

  private var apiKeySection: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("API KEY").font(.caption2.bold()).tracking(0.8).foregroundStyle(
        BeetTheme.secondaryText(appearance))
      HStack(spacing: 8) {
        Picker("Provider", selection: $keyProviderID) {
          Text("OpenAI").tag("openAI")
          Text("Gemini").tag("gemini")
          Text("OpenRouter").tag("openRouter")
          Text("Anthropic").tag("anthropic")
          Text("DeepSeek").tag("deepSeek")
          Text("OpenCode Zen").tag("openCode")
          Text("OpenCode Go").tag("openCodeGo")
        }.pickerStyle(.menu)
        SecureField("Paste key", text: $keyDraft)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button(isSavingKey ? "Saving…" : "Save") { saveAPIKey() }
          .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
      }
      if let keyMessage {
        Text(keyMessage).font(.caption).foregroundStyle(BeetTheme.secondaryText(appearance))
      }
      Text("Stored securely in the Mac Keychain; the key is never saved on this device or in chat.")
        .font(.caption2).foregroundStyle(BeetTheme.secondaryText(appearance))
    }
  }

  private func saveAPIKey() {
    isSavingKey = true
    let key = keyDraft
    Task {
      let saved = await store.saveAPIKey(providerID: keyProviderID, key: key)
      if saved {
        keyDraft = ""
        source = "api"
        await store.loadStartModels()
        selectFirstModel()
        let count = store.startModels.filter { $0.source == "api" }.count
        keyMessage =
          count == 0
          ? "Saved on Mac, but no models came back yet."
          : "Saved. Loaded \(count) API models."
      } else {
        keyMessage = "Could not save the key."
      }
      isSavingKey = false
    }
  }

  private func startBotComputer(_ computer: RemoteBotComputer) {
    botComputerBusyID = computer.id
    Task {
      if await store.startBotComputer(computer.id) {
        await loadBotComputers()
        selectedBotComputerID = computer.id
        sessionMode = .code
      }
      botComputerBusyID = nil
    }
  }

  private func stopBotComputer(_ computer: RemoteBotComputer) {
    botComputerBusyID = computer.id
    Task {
      if await store.stopBotComputer(computer.id) {
        await loadBotComputers()
        if selectedBotComputerID == computer.id { selectedBotComputerID = nil }
      }
      botComputerBusyID = nil
    }
  }
  private func start() {
    isStarting = true
    let firstMessage = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedReasoningEffort = selectedReasoningEffort
    let autoMode = autoMode
    let fullAccess = fullAccess
    let sessionMode = sessionMode
    Task {
      if let id = await store.startSession(
        modelID: selectedModelID,
        message: firstMessage,
        botProfileID: RemoteBotProfile.resolvedID(selectedBotID),
        botComputerID: selectedBotComputerID,
        workspacePath: sessionMode == .code && selectedBotComputerID == nil
          ? selectedWorkspacePath : nil,
        chatOnly: sessionMode == .chat && selectedBotComputerID == nil,
        autoMode: autoMode,
        fullAccess: fullAccess,
        reasoningEffort: selectedReasoningEffort)
      {
        onStarted(id)
      }
      isStarting = false
    }
  }
}
