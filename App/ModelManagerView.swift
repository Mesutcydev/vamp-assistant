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
    /// What you already have comes first. Opening on Discover put a download
    /// catalogue in front of someone whose models are already on the machine —
    /// the page's job is "what runs my next message", and that answer lives in
    /// Downloaded and Connected, not in a store.
    @State private var libraryFilter = "Downloaded"
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

            // Library section switch. Order follows what you already have;
            // each segment stays individually reachable from UI tests.
            InstrumentSegmentedControl(
                selection: $libraryFilter,
                options: [("Downloaded", "Downloaded"),
                          ("Connected", "Connected models"),
                          ("Discover", "Discover")])
                .frame(maxWidth: 360)
                .padding(.vertical, 16)
                .accessibilityLabel("Model library filter")

            if libraryFilter == "Connected models" {
                ModelPickerPopover()
                    .frame(height: 520)
            } else if embedded {
                LocalModelsSection(query: searchText, installedOnly: libraryFilter == "Downloaded")
            } else {
                ScrollView {
                    LocalModelsSection(query: searchText, installedOnly: libraryFilter == "Downloaded")
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

                HStack {
                    Label(device.summary, systemImage: "desktopcomputer")
                    Spacer()
                    Label("\(ByteFormatter.bytes(freeBytes)) available memory", systemImage: "circle.fill")
                        .foregroundStyle(Theme.positive)
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
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

        if QwenStreamArtifact.recognizesConfiguration(url) {
            _ = try QwenStreamArtifact.inspect(url)
            try QwenStreamArtifact.verifyPayloads(url)
            var model = ModelCatalog.bundled.first { $0.id == QwenStreamArtifact.modelID }!
            // Keep external models in place. The bookmark is private user
            // state; uninstall forgets this registration without deleting files.
            model.directoryBookmark = try url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            return model
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
        let pattern = #"(?i)[\-_.](PQ\d(?:_\d)?|PTQ\d(?:_\d)?|Q\d(?:_K)?(?:_[SMXL])?|IQ\d(?:_[A-Z\d]+)?|F(?:16|32|8_0)|BF16)(?=[\-_.]|$)"#
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
    var installedOnly = false
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
            let visible = models.filter { !installedOnly || keepIDs.contains($0.id) }
            guard !visible.isEmpty else { return nil }
            return CatalogLibrary.Section(id: section.id, models: visible)
        }
        LazyVStack(alignment: .leading, spacing: Spacing.lg) {
            if sections.isEmpty {
                ContentUnavailableView(installedOnly ? "No downloaded models" : "No matching models", systemImage: "shippingbox", description: Text(installedOnly ? "Find a model in Discover and download it to get started." : "Try a different name or model family."))
            } else {
                ForEach(sections) { section in
                    LazyVStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: section.title, systemImage: section.systemImage)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                            ForEach(section.models) { model in
                                ModelCard(model: model, isRecommended: recommended.contains(model.id))
                            }
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
    @State private var showDetails = false

    private var downloadState: ModelDownloadManager.State {
        appState.downloadManager.state(for: model.id)
    }

    private var budget: MemoryAdvisor.Budget { appState.budget(for: model) }

    private var isActive: Bool { appState.activeModelID == model.id }

    /// One colour per capability, so the library can be scanned by what a model
    /// is for instead of read card by card.
    private var capabilityTint: Color {
        if model.role == .vision { return Theme.tintVision }
        return model.kind == .coding ? Theme.tintCoding : Theme.tintChat
    }

    private var capabilityLabel: String {
        if model.role == .vision { return "Vision sidecar" }
        return model.kind == .coding ? "Coding" : "General chat"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                ModelGlyph(format: model.format, isActive: isActive, tint: capabilityTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(capabilityLabel)
                        .font(.app(size: 11, weight: .semibold))
                        .foregroundStyle(capabilityTint)
                    if isRecommended {
                        Text("Recommended for this Mac")
                            .font(.app(size: 10.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer(minLength: 0)
                VerdictBadge(verdict: isActive ? .fits : budget.verdict, projectedFootprint: budget.projectedFootprint)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(model.displayName)
                    .font(.app(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                sizeChips
            }
            Text(model.notes)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .frame(height: 36, alignment: .topLeading)
            DownloadStatusView(state: downloadState)
            if showDetails {
                specReadout
                if !isActive, case .wontFit(let reason) = budget.verdict {
                    Text(reason).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Button(showDetails ? "Less" : "Details") { showDetails.toggle() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textSecondary)
                ModelActions(model: model, isActive: isActive, downloadState: downloadState, budget: budget)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [Theme.sectionSurfaceTop, Theme.sectionSurface, Theme.sectionSurfaceBottom],
                    startPoint: .top, endPoint: .bottom)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Theme.positive : Theme.sectionStroke,
                              lineWidth: isActive ? 1.5 : 1))
        .shadow(color: Theme.cardShadow, radius: 6, y: 2)
    }

    /// Parameters, precision and size as scannable chips rather than one run-on
    /// sentence. Installed rows use the measured on-disk size; the catalog
    /// estimate (~) only labels models that are not here yet.
    private var sizeChips: some View {
        HStack(spacing: 6) {
            SpecChip(text: model.parameters)
            SpecChip(text: model.quantization)
            if let installed = appState.modelStore.installedModel(id: model.id),
               appState.modelStore.isInstalled(catalogModel: model) {
                SpecChip(text: ByteFormatter.bytes(installed.sizeBytes))
            } else {
                // Catalog size is an estimate, so it is labelled as one.
                SpecChip(text: "~" + ByteFormatter.bytes(model.diskBytes))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.parameters), \(model.quantization), \(model.subtitle)")
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
    var tint: Color = Instrument.accentOrange

    var body: some View {
        let mark = isActive ? Theme.positive : tint
        Image(systemName: format == .gguf ? "shippingbox" : (format == .coreAI ? "apple.intelligence" : "cpu"))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(mark)
            .frame(width: 32, height: 32)
            .background(mark.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(mark.opacity(0.28), lineWidth: 0.75))
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
