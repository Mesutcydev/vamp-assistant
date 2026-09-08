import SwiftUI
import UniformTypeIdentifiers

/// The Models workspace. One scrolling column of cards: local catalog models
/// first, then remote (BYOK) providers. Each card surfaces the model's
/// identity, fit verdict and specs at a glance, with exactly one prominent
/// action and everything destructive tucked into an overflow menu.
struct ModelManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Models is normally rendered as a Settings destination.  The standalone
    /// variant remains available for older callers, but no longer determines
    /// the sheet size or navigation flow.
    let embedded: Bool
    /// True while an import validation/copy runs off-main — multi-GB copies
    /// must never block the UI.
    @State private var importInProgress = false
    @State private var searchText = ""
    private let device = DeviceProfile.current()

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: 0) {
            if !embedded {
                ManagerHeaderView(
                    device: device,
                    recommendedName: CatalogLibrary.recommendedChat(device: device)?.displayName,
                    freeBytes: appState.availableBudget,
                    totalBytes: MemoryAdvisor.physicalMemory,
                    importing: importInProgress,
                    onImport: importModel,
                    onDone: { dismiss() })
            }

            ModelManagerLibraryBar(
                searchText: $searchText,
                localCount: CatalogLibrary.sections(
                    device: device,
                    keepIDs: Set(appState.modelStore.installed.map(\.id))
                ).reduce(0) { $0 + $1.models.count },
                device: device,
                freeBytes: appState.availableBudget,
                totalBytes: MemoryAdvisor.physicalMemory,
                recommendedName: CatalogLibrary.recommendedChat(device: device)?.displayName,
                importing: importInProgress,
                showsImport: embedded,
                embedded: embedded,
                onImport: importModel
            )

            if embedded {
                // Inside Settings the shared column owns width and the shell
                // owns scrolling — a nested scroll view here would double-
                // scroll and a second centering rule would fight the column.
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    LocalModelsSection(query: searchText)
                    RemoteSection()
                        .environmentObject(appState)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        LocalModelsSection(query: searchText)
                        RemoteSection()
                            .environmentObject(appState)
                    }
                    .vampPageColumn()
                }
            }
        }
        // Embedded in Settings the window root already owns the single
        // continuous atmosphere; only the standalone variant needs its own.
        .background { if !embedded { Theme.workspaceCanvas } }
        .frame(maxWidth: .infinity)
        .tint(Theme.accent)
        // Re-sync with reality every open: models imported/copied/deleted
        // outside the registry (or left unregistered by an interrupted
        // import) must not show stale Download/Load states.
        .onAppear { appState.modelStore.rescanFromDisk() }
    }

    /// Search and catalog metadata sit in their own stable row so the header
    /// stays focused on hardware budget and import actions.
    private struct ModelManagerLibraryBar: View {
        @Binding var searchText: String
        let localCount: Int
        let device: DeviceProfile
        let freeBytes: UInt64
        let totalBytes: UInt64
        let recommendedName: String?
        let importing: Bool
        let showsImport: Bool
        var embedded: Bool = false
        let onImport: () -> Void

        private var usedFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(1, max(0, 1 - Double(freeBytes) / Double(totalBytes)))
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(alignment: .center, spacing: Spacing.md) {
                    VampSearchField(placeholder: "Filter models", text: $searchText)
                        .frame(maxWidth: .infinity)

                    Spacer(minLength: Spacing.md)

                    if showsImport {
                        if importing {
                            ProgressView()
                                .controlSize(.small)
                                .help("Importing model…")
                        } else {
                            Button("Import…", action: onImport)
                                .buttonStyle(LFCapsuleButtonStyle(height: 34))
                                .help("Import a local MLX, GGUF, or Apple Core AI model pack")
                        }
                    }
                }

                HStack(alignment: .center, spacing: Spacing.md) {
                    Label("RAM", systemImage: "memorychip")
                        .font(.app(size: 11.5, weight: .medium ))
                        .foregroundStyle(Theme.textSecondary)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surfaceInset)
                            Capsule()
                                .fill(Theme.accentGradient)
                                .frame(width: max(4, proxy.size.width * usedFraction))
                        }
                    }
                    .frame(height: 4)
                    Text("\(ByteFormatter.bytes(freeBytes)) free")
                        .font(.app(size: 11 ))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }

                HStack(spacing: 0) {
                    rackReadout(label: "AVAILABLE", value: "\(localCount)")
                    rackDivider
                    rackReadout(label: "MACHINE", value: device.summary)
                    if let recommendedName {
                        rackDivider
                        rackReadout(label: "DAILY PICK", value: recommendedName)
                    }
                }
            }
            .padding(.horizontal, embedded ? 12 : Chrome.pageHPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .instrumentFaceplate(radius: 10, shadow: false)
        }

        private func rackReadout(label: String, value: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Instrument.microLabel(label)
                Text(value)
                    .font(.appMono(size: 10.5, weight: .medium))
                    .foregroundStyle(Instrument.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var rackDivider: some View {
            Rectangle()
                .fill(Instrument.seam.opacity(0.55))
                .frame(width: 0.75, height: 28)
        }
    }

    /// Pick a local model — MLX, GGUF, or an Apple Core AI resource pack — and
    /// register it as a user-catalog model.
    private func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Import local model"
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, UTType(filenameExtension: "gguf") ?? .data]
        panel.message = "Select an MLX folder, a .gguf model, or a Core AI pack (metadata.json + .aimodel)."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let base = appState.modelStore.modelsBaseURL
        importInProgress = true
        Task {
            defer { importInProgress = false }
            do {
                // Validation and the (possibly multi-GB) copy run off-main.
                let catalog = try await Task.detached(priority: .userInitiated) {
                    try Self.prepareImport(from: url, modelsBase: base)
                }.value
                var userModels = ModelCatalog.loadUserModels()
                userModels.removeAll { $0.id == catalog.id }
                userModels.append(catalog)
                ModelCatalog.saveUserModels(userModels)
                _ = appState.modelStore.register(catalogModel: catalog, sizeBytes: catalog.diskBytes)
                appState.modelStore.objectWillChange.send()
            } catch {
                presentImportError(error.localizedDescription)
            }
        }
    }

    private enum ImportError: Error, LocalizedError {
        case notAModel
        case missingConfig
        case missingWeights
        case incompleteDownloads
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAModel:
                "Choose an MLX model folder, a .gguf model, or a Core AI pack."
            case .missingConfig:
                "No config.json found in the selected folder."
            case .missingWeights:
                "No MLX, GGUF, or Core AI model resources were found in the selected folder."
            case .incompleteDownloads:
                "The folder contains incomplete downloads (.incomplete files). Finish the download first."
            case .copyFailed(let detail):
                "Copy failed: \(detail)"
            }
        }
    }

    /// Validates the selection, copies it into the managed Models directory
    /// (unless already there) and returns the catalog entry. Called off-main.
    nonisolated private static func prepareImport(from url: URL, modelsBase: URL) throws -> CatalogModel {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ImportError.notAModel
        }

        // Single .gguf file: wrap it in a managed folder named after the file.
        if !isDirectory.boolValue {
            guard url.pathExtension.lowercased() == "gguf" else { throw ImportError.notAModel }
            let stem = url.deletingPathExtension().lastPathComponent
            let destDir = modelsBase.appendingPathComponent(stem, isDirectory: true)
            let destFile = destDir.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: destFile.path) {
                do {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    try fm.copyItem(at: url, to: destFile)
                } catch {
                    throw ImportError.copyFailed(error.localizedDescription)
                }
            }
            let size = fileSize(at: destFile)
            // Sniff the copied file's GGUF header for the real architecture
            // and training context length; the fallbacks match llama-server's
            // --ctx-size default so utilization % stays honest when the
            // header can't be read.
            let sniffed = GGUFMetadata.read(from: destFile)
            return CatalogModel(
                id: stem,
                repo: url.path,
                displayName: prettifiedName(stem),
                family: sniffed?.architecture?.capitalized ?? "GGUF",
                parameters: "—",
                quantization: ggufQuantization(stem) ?? "GGUF",
                diskBytes: size,
                contextWindow: sniffed?.contextLength ?? 8_192,
                minRAMGB: max(6, Int(Double(size) / 1_000_000_000 * 1.5)),
                recommendedRAMGB: max(8, Int(Double(size) / 1_000_000_000 * 2)),
                notes: "Imported from \(url.path)",
                format: .gguf,
                kind: CatalogModel.Kind.inferred(
                    family: sniffed?.architecture?.capitalized ?? "GGUF",
                    role: .chat,
                    id: stem),
                lanes: [])
        }

        // Folder import: MLX, GGUF, or a recursively nested Core AI pack.
        let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if contents.contains(where: { $0.hasSuffix(".incomplete") }) {
            throw ImportError.incompleteDownloads
        }
        let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }
        let hasGGUF = contents.contains { $0.lowercased().hasSuffix(".gguf") }
        let hasCoreAI = ModelStore.isCompleteCoreAIPack(at: url)
        let format: CatalogModel.Format
        if hasCoreAI {
            format = .coreAI
        } else if hasSafetensors {
            guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
                throw ImportError.missingConfig
            }
            format = .mlx
        } else if hasGGUF {
            format = .gguf
        } else {
            throw ImportError.missingWeights
        }

        // Read model config for display metadata when present (GGUF folders
        // usually ship no config.json). MLXModelInspector also understands
        // nested Qwen3.5 text/vision configs and their quantization metadata.
        var family = format == .gguf ? "GGUF" : (format == .coreAI ? "Core AI" : "Custom")
        var contextWindow = format == .gguf || format == .coreAI ? 8_192 : 32_768
        var parameters = "—"
        var quantization = format == .gguf
            ? (ggufQuantization(url.lastPathComponent) ?? "GGUF")
            : (format == .coreAI ? "Core AI" : "—")
        var mlxMetadata: MLXModelInspector.Metadata?
        if format == .mlx, let metadata = MLXModelInspector.read(from: url) {
            mlxMetadata = metadata
            family = metadata.family
            contextWindow = metadata.contextWindow
            parameters = metadata.parameters
            quantization = metadata.quantization
        }

        // GGUF folders: the header inside the .gguf is the source of truth —
        // it wins over any config.json the folder happens to carry.
        if format == .gguf,
           let ggufName = contents.first(where: { $0.lowercased().hasSuffix(".gguf") }),
           let sniffed = GGUFMetadata.read(from: url.appendingPathComponent(ggufName)) {
            if let contextLength = sniffed.contextLength { contextWindow = contextLength }
            if let architecture = sniffed.architecture { family = architecture.capitalized }
        }

        let dirName = MLXModelInspector.suggestedID(for: url)
        let size = (try? ModelStore.sizeOfDirectory(url)) ?? 0
        let displayName = mlxMetadata.map {
            MLXModelInspector.displayName(for: url, metadata: $0)
        } ?? prettifiedName(dirName)

        // Copy into the managed Models directory if it isn't already there.
        let dest = modelsBase.appendingPathComponent(dirName, isDirectory: true)
        if !fm.fileExists(atPath: dest.path) {
            do {
                try fm.copyItem(at: url, to: dest)
            } catch {
                throw ImportError.copyFailed(error.localizedDescription)
            }
        }

        return CatalogModel(
            id: dirName,
            repo: url.path,
            displayName: displayName,
            family: family,
            parameters: parameters,
            quantization: quantization,
            diskBytes: size,
            contextWindow: contextWindow,
            minRAMGB: max(6, Int(Double(size) / 1_000_000_000 * 1.5)),
            recommendedRAMGB: max(8, Int(Double(size) / 1_000_000_000 * 2)),
            notes: format == .coreAI
                ? "Imported Apple Core AI pack from \(url.path). Not runnable yet — use MLX or GGUF."
                : mlxMetadata?.isVisionLanguage == true
                ? "Imported multimodal MLX model (text + vision weights) from \(url.path)"
                : "Imported from \(url.path)",
            format: format,
            kind: mlxMetadata?.isVisionLanguage == true
                ? .vision
                : CatalogModel.Kind.inferred(family: family, role: .chat, id: dirName),
            lanes: [])
    }

    /// "qwen3-4b-4bit" → "Qwen3 4b 4bit".
    nonisolated private static func prettifiedName(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Extracts a quantization label from a GGUF name
    /// ("…-Q4_K_M.gguf" → "Q4_K_M").
    nonisolated private static func ggufQuantization(_ stem: String) -> String? {
        let pattern = #"(?i)[\-_.](Q\d(?:_K)?(?:_[SMXL])?|IQ\d(?:_[A-Z\d]+)?|F(?:16|32|8_0)|BF16)(?=[\-_.]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: stem)
        else { return nil }
        return String(stem[range]).uppercased()
    }

    nonisolated private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func presentImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Header

/// Title row + a live RAM-budget gauge, so the user sees headroom at a
/// glance instead of parsing a caption.
private struct ManagerHeaderView: View {
    let device: DeviceProfile
    let recommendedName: String?
    let freeBytes: UInt64
    let totalBytes: UInt64
    var importing: Bool = false
    let onImport: () -> Void
    let onDone: () -> Void

    private var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, 1 - Double(freeBytes) / Double(totalBytes)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models")
                    .font(.app(size: 17, weight: .semibold ))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if importing {
                    ProgressView()
                        .controlSize(.small)
                        .help("Importing model…")
                } else {
                    Button("Import…", action: onImport)
                        .buttonStyle(LFCapsuleButtonStyle(height: 34))
                        .help("Import a local MLX, GGUF, or Apple Core AI model pack")
                }
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(LFCapsuleButtonStyle(tone: .primary, height: 34))
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Label(device.summary, systemImage: "cpu")
                        .font(.app(size: 11.5, weight: .medium ))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(device.catalogCaption)
                        .font(.app(size: 11.5 ))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if let recommendedName {
                    Text("Daily pick: \(recommendedName)")
                        .font(.app(size: 11.5 ))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                HStack {
                    Label("RAM budget", systemImage: "memorychip")
                        .font(.app(size: 11.5, weight: .medium ))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("\(ByteFormatter.bytes(freeBytes)) free of \(ByteFormatter.bytes(totalBytes))")
                        .font(.app(size: 11.5 ))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceInset)
                        Capsule()
                            .fill(Theme.accentGradient)
                            .frame(width: max(4, proxy.size.width * usedFraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, Chrome.pageHPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.75)
        }
    }
}

// MARK: - Local models

private struct LocalModelsSection: View {
    @EnvironmentObject private var appState: AppState
    let query: String
    private let device = DeviceProfile.current()

    var body: some View {
        let keepIDs = Set(appState.modelStore.installed.map(\.id))
        let recommended = CatalogLibrary.recommendedIDs(device: device)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sections = CatalogLibrary.sections(device: device, keepIDs: keepIDs).compactMap { section -> CatalogLibrary.Section? in
            let models = normalizedQuery.isEmpty
                ? section.models
                : section.models.filter {
                    $0.displayName.lowercased().contains(normalizedQuery)
                        || $0.family.lowercased().contains(normalizedQuery)
                        || $0.format.rawValue.lowercased().contains(normalizedQuery)
                }
            guard !models.isEmpty else { return nil }
            return CatalogLibrary.Section(id: section.id, models: models)
        }
        LazyVStack(alignment: .leading, spacing: Spacing.lg) {
            if sections.isEmpty, !normalizedQuery.isEmpty {
                ModelManagerEmptySearch(query: query)
            } else {
                ForEach(sections) { section in
                    LazyVStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: section.title, systemImage: section.systemImage)
                        ForEach(section.models) { model in
                            ModelCard(model: model, isRecommended: recommended.contains(model.id))
                        }
                    }
                }
            }
        }
    }
}

private struct ModelManagerEmptySearch: View {
    let query: String

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No models found")
                    .font(.app(size: 13, weight: .semibold ))
                    .foregroundStyle(Theme.textPrimary)
                Text("Try a different search than \"\(query)\".")
                    .font(.app(size: 11.5 ))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .vampOutlineCard()
    }
}

/// Small uppercase section label with a glyph.
private struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(title.uppercased())
                .font(.appUI(size: 10, weight: .semibold))
                .tracking(1)
            Rectangle()
                .fill(Instrument.seam.opacity(0.45))
                .frame(height: 0.75)
        }
        .foregroundStyle(Instrument.engraved)
        .padding(.horizontal, 4)
    }
}

// MARK: - Model card

private struct ModelCard: View {
    @EnvironmentObject private var appState: AppState
    let model: CatalogModel
    var isRecommended: Bool = false
    @State private var compact = false

    private var downloadState: ModelDownloadManager.State {
        appState.downloadManager.state(for: model.id)
    }

    private var budget: MemoryAdvisor.Budget { appState.budget(for: model) }

    private var isActive: Bool { appState.activeModelID == model.id }

    var body: some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.md))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.md))
        layout {
        HStack(alignment: .top, spacing: Spacing.md) {
            ModelGlyph(format: model.format, isActive: isActive)
                .padding(.trailing, Spacing.md)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Instrument.seam.opacity(0.45))
                        .frame(width: 0.75)
                        .padding(.vertical, 2)
                }

            VStack(alignment: .leading, spacing: 5) {
                titleRow
                sizeLine
                specReadout
                if !model.notes.isEmpty {
                    Text(model.notes)
                        .font(.appUI(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                if !isActive, case .wontFit(let reason) = budget.verdict {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(3)
                }
                DownloadStatusView(state: downloadState)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

            ModelActions(model: model, isActive: isActive, downloadState: downloadState, budget: budget)
                .padding(.leading, Spacing.md)
                .frame(width: 124, alignment: .trailing)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Instrument.seam.opacity(0.45))
                        .frame(width: 0.75)
                        .padding(.vertical, 2)
                }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Chrome.cardHPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .instrumentFaceplate(radius: Radius.card, shadow: false)
        .onGeometryChange(for: Bool.self) { $0.size.width < 620 } action: { compact = $0 }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(Theme.positive)
                    .frame(width: 3, height: 36)
                    .padding(.leading, 4)
            }
        }
    }

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(model.displayName)
                .font(.app(size: 13.5, weight: .semibold ))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            HStack(spacing: Spacing.sm) {
            if !compact {
            VampTag(text: model.family)
            if model.kind == .coding {
                VampTag(text: "Coding")
            } else if model.kind == .vision {
                VampTag(text: "Vision")
            }
            }
            VerdictBadge(verdict: isActive ? .fits : budget.verdict,
                         projectedFootprint: budget.projectedFootprint)
            if isRecommended, !isActive {
                Label("Daily pick", systemImage: "star.fill")
                    .font(.app(size: 11, weight: .medium ))
                    .foregroundStyle(Theme.textSecondary)
            }
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.app(size: 11, weight: .medium ))
                    .foregroundStyle(Theme.positive)
            }
            }
        }
    }

    /// Parameters · quantization · size. Installed rows use the measured
    /// on-disk size; the catalog estimate (~) only labels pending downloads.
    @ViewBuilder
    private var sizeLine: some View {
        if let installed = appState.modelStore.installedModel(id: model.id),
           appState.modelStore.isInstalled(catalogModel: model) {
            Text("\(model.parameters) · \(model.quantization) · \(ByteFormatter.bytes(installed.sizeBytes))")
                .font(.app(size: 11.5 ))
                .foregroundStyle(Theme.textSecondary)
        } else {
            Text(model.subtitle)
                .font(.app(size: 11.5 ))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var specReadout: some View {
        HStack(spacing: 12) {
            technicalValue("CONTEXT", "\(model.contextWindow / 1024)K")
            technicalValue("MIN", "\(model.minRAMGB) GB")
            technicalValue("REC", "\(model.recommendedRAMGB) GB")
        }
    }

    private func technicalValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.appUI(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Instrument.inkSecondary)
            Text(value)
                .font(.appMono(size: 10.5, weight: .medium))
                .foregroundStyle(Instrument.ink)
        }
    }
}

/// Leading icon tile for a model card.
private struct ModelGlyph: View {
    let format: CatalogModel.Format
    let isActive: Bool

    var body: some View {
        Image(systemName: format == .gguf ? "shippingbox" : (format == .coreAI ? "apple.intelligence" : "cpu"))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: 32, height: 32)
            .instrumentRecess(radius: Chrome.buttonRadius)
    }
}

/// Tiny capsule for one spec (context window, RAM floors). Kept as an alias
/// so older call sites keep compiling; VampTag is the shared implementation.
private struct SpecChip: View {
    let text: String

    var body: some View {
        VampTag(text: text, monospaced: true)
    }
}

/// Fit verdict as a quiet tag so it scans like a status light without
/// introducing a tinted capsule family of its own.
private struct VerdictBadge: View {
    let verdict: MemoryAdvisor.Verdict
    let projectedFootprint: UInt64

    var body: some View {
        let (label, tint): (String, Color) = {
            switch verdict {
            case .fits:     return ("Fits", Theme.positive)
            case .marginal: return ("Marginal", Theme.warning)
            case .wontFit:  return ("Won't fit", Theme.negative)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label.uppercased())
                .font(.appUI(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Instrument.inkSecondary)
        }
            .help("Projected peak: \(ByteFormatter.bytes(projectedFootprint))")
    }
}

/// Download lifecycle status under the card text — preparing spinner,
/// progress bar, paused note or failure message.
private struct DownloadStatusView: View {
    let state: ModelDownloadManager.State

    var body: some View {
        switch state {
        case .preparing:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Contacting Hugging Face…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.accent)
                    .frame(maxWidth: 320)
                Text("\(ByteFormatter.bytes(progress.completedBytes)) of \(ByteFormatter.bytes(progress.totalBytes)) — \(progress.currentFile)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .paused(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress.fraction)
                    .tint(Theme.warning)
                    .frame(maxWidth: 320)
                Text("Paused at \(ByteFormatter.bytes(progress.completedBytes)) — resumes from here")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }
}

// MARK: - Card actions

/// Exactly one prominent action plus an overflow menu for destructive or
/// secondary commands, so the card never shows a jagged stack of buttons.
private struct ModelActions: View {
    @EnvironmentObject private var appState: AppState
    let model: CatalogModel
    let isActive: Bool
    let downloadState: ModelDownloadManager.State
    let budget: MemoryAdvisor.Budget

    private var isInstalled: Bool {
        appState.modelStore.isInstalled(catalogModel: model)
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            primaryAction
            overflowMenu
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .font(.appUI(size: 12.5, weight: .medium))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if isInstalled {
            if model.role == .vision {
                // Vision sidecars are never loaded by hand — the app runs
                // them automatically when an image needs describing.
                InstrumentSignal(label: "Auto vision", on: true)
                    .help("Downloaded. Vamp Assistant uses this model automatically to describe image attachments and screenshots.")
            } else if isActive {
                Button("Unload") {
                    Task { await appState.deactivate() }
                }
                .buttonStyle(LFCapsuleButtonStyle())
            } else {
                Button("Load") {
                    Task { await appState.activate(model: model) }
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .disabled(budget.verdict.fitsLoad == false)
            }
        } else {
            switch downloadState {
            case .preparing, .downloading:
                Button("Pause") {
                    appState.pauseDownload(of: model)
                }
                .buttonStyle(LFCapsuleButtonStyle())
            case .paused:
                Button("Resume") {
                    appState.startDownload(of: model)
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            case .failed:
                Button("Retry") {
                    appState.startDownload(of: model)
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            case .completed:
                ProgressView().controlSize(.small)
            case .idle:
                // RAM gates LOADING, not downloading: the user may be
                // storing the model for later or for another machine.
                Button("Download") {
                    appState.startDownload(of: model)
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
                .help("Resumable download with integrity checks")
            }
        }
    }

    @ViewBuilder
    private var overflowMenu: some View {
        if isInstalled {
            Menu {
                Button("Remove…", role: .destructive, action: removeInstalled)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.app(size: 13, weight: .semibold ))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions for \(model.displayName)")
        } else {
            switch downloadState {
            case .preparing, .downloading, .paused:
                Menu {
                    Button("Cancel Download", role: .destructive) {
                        appState.cancelDownload(of: model)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.app(size: 13, weight: .semibold ))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("Download actions for \(model.displayName)")
            default:
                EmptyView()
            }
        }
    }

    private func removeInstalled() {
        guard let installed = appState.modelStore.installedModel(id: model.id) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(model.displayName)?"
        alert.informativeText = "Deletes \(ByteFormatter.bytes(installed.sizeBytes)) from disk. You can download it again later."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if appState.activeModelID == model.id {
                Task {
                    await appState.deactivate()
                    appState.modelStore.uninstall(installed)
                }
            } else {
                appState.modelStore.uninstall(installed)
            }
        }
    }
}

// MARK: - Remote (BYOK)

/// BYOK remote providers — activate one to run the agent without a local
/// model download. Rendered as a proper legible panel: a real header row,
/// full-size provider rows, and a bounded scroll region so many configured
/// providers never push the sheet off-screen or clip their own text.
private struct RemoteSection: View {
    @EnvironmentObject private var appState: AppState

    private var configured: [LLMProvider] {
        APIKeyStore.shared.configuredProviders.sorted {
            $0.displayName < $1.displayName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(title: "Remote (BYOK)", systemImage: "cloud")

            VStack(alignment: .leading, spacing: Spacing.sm) {
                if configured.isEmpty {
                    HStack(spacing: Spacing.md) {
                        Image(systemName: "key")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No providers configured")
                                .font(.app(size: 13, weight: .medium ))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Add an API key in Settings → Providers to run the agent on a remote model.")
                                .font(.app(size: 11.5 ))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: Spacing.xs) {
                            ForEach(configured) { provider in
                                providerRow(provider)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            }
            .vampOutlineCard()
        }
    }

    private func providerRow(_ provider: LLMProvider) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.app(size: 12.5, weight: .medium ))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(modelID(for: provider))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Spacing.md)
            if appState.isRemoteActive,
               appState.engine.activeRemoteEndpoint?.provider == provider {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.app(size: 11, weight: .medium ))
                    .foregroundStyle(Theme.positive)
                Button("Use local") {
                    appState.deactivateRemote()
                }
                .buttonStyle(LFCapsuleButtonStyle())
            } else {
                // Same rule as the model cards: the forward action is the
                // single prominent button.
                Button("Use remote") {
                    let endpoint = RemoteEndpoint(
                        provider: provider,
                        model: modelID(for: provider))
                    Task {
                        _ = await appState.activateRemote(endpoint: endpoint)
                    }
                }
                .buttonStyle(LFCapsuleButtonStyle(tone: .primary))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(Theme.surfaceInset.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: Chrome.buttonRadius, style: .continuous))
    }

    private func modelID(for provider: LLMProvider) -> String {
        AppPreferencesStore.shared.current.remoteModel[provider.rawValue]
            ?? provider.defaultModel
    }
}
