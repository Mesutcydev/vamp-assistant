import SwiftUI

// MARK: - Searchable model picker

/// The one place the iOS client lists models.
///
/// The new-session sheet used to render every model inline with no search, and
/// the in-conversation switcher used a `Menu` — both fall apart the moment a
/// gateway like OpenRouter contributes a few hundred API models. This is a
/// searchable, sectioned, counted list instead, presented as a sheet from both.
struct RemoteModelPickerSheet: View {
    let models: [RemoteStartModelOption]
    @Binding var source: String
    @Binding var selectedModelID: String
    /// Called with the chosen model so callers can also apply its default
    /// reasoning effort without re-looking it up.
    var onSelect: (RemoteStartModelOption) -> Void = { _ in }
    /// Pull-to-refresh, so a model configured on the Mac while this sheet is
    /// open can be picked up without closing and reopening it.
    var onRefresh: (() async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteAppearance) private var appearance
    @State private var query = ""

    static let sources = ["local", "chatgpt", "api"]

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "chatgpt": "ChatGPT"
        case "api": "API"
        default: "Local"
        }
    }

    static func sourceIcon(_ source: String) -> String {
        switch source {
        case "chatgpt": "person.crop.circle"
        case "api": "cloud"
        default: "cpu"
        }
    }

    private var inSource: [RemoteStartModelOption] {
        models.filter { $0.source == source }
    }

    /// Matches name, model id, and the provider shown in `detail`, so an exact
    /// id typed from a provider's docs finds its model.
    private var filtered: [RemoteStartModelOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return inSource }
        return inSource.filter { model in
            [model.name, model.id, model.detail].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// API models come from many providers at once; grouping by `detail` keeps
    /// each provider's models together instead of interleaving them.
    private var groups: [(title: String, models: [RemoteStartModelOption])] {
        guard source == "api" else {
            return filtered.isEmpty ? [] : [(Self.sourceLabel(source), filtered)]
        }
        let byProvider = Dictionary(grouping: filtered, by: \.detail)
        return byProvider.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ($0, byProvider[$0]!.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
    }

    private var emptyDescription: String {
        switch source {
        case "chatgpt": "Sign in with ChatGPT on your Mac, then refresh."
        case "api": "Configure an API provider on your Mac first."
        default: "Download a model on your Mac first."
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RemoteBackdrop()
                VStack(spacing: 0) {
                    Picker("Model source", selection: $source) {
                        ForEach(Self.sources, id: \.self) { option in
                            let count = models.filter { $0.source == option }.count
                            Text(count > 0 ? "\(Self.sourceLabel(option)) \(count)" : Self.sourceLabel(option))
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                    if inSource.isEmpty {
                        ContentUnavailableView(
                            "No \(Self.sourceLabel(source)) models",
                            systemImage: Self.sourceIcon(source),
                            description: Text(emptyDescription))
                        .frame(maxHeight: .infinity)
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(groups, id: \.title) { group in
                                Section {
                                    ForEach(group.models) { model in
                                        row(model)
                                    }
                                } header: {
                                    Text("\(group.title.uppercased()) · \(group.models.count)")
                                        .font(.caption2.bold())
                                        .tracking(0.8)
                                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                                }
                                .listRowBackground(BeetTheme.surface(appearance))
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .refreshable { await onRefresh?() }
                    }
                }
                .padding(.top, 10)
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search name, id, or provider")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .toolbarBackground(BeetTheme.background(appearance).opacity(0.94), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func row(_ model: RemoteStartModelOption) -> some View {
        Button {
            selectedModelID = model.id
            onSelect(model)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedModelID == model.id
                      ? "checkmark.circle.fill" : Self.sourceIcon(model.source))
                    .foregroundStyle(selectedModelID == model.id
                                     ? BeetTheme.accentBright : BeetTheme.secondaryText(appearance))
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.body.weight(.semibold))
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .accessibilityAddTraits(selectedModelID == model.id ? .isSelected : [])
        }
        .buttonStyle(.plain)
    }
}

/// The summary row that opens the picker. Shows the current model, its source,
/// and how many are available, so the size of the catalog is visible without
/// opening anything.
struct RemoteModelSummaryRow: View {
    let models: [RemoteStartModelOption]
    let selectedModelID: String
    let action: () -> Void
    @Environment(\.remoteAppearance) private var appearance

    private var selected: RemoteStartModelOption? {
        models.first { $0.id == selectedModelID }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: RemoteModelPickerSheet.sourceIcon(selected?.source ?? "local"))
                    .foregroundStyle(BeetTheme.accentBright)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selected?.name ?? "Choose a model")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(selected?.detail ?? "\(models.count) available")
                        .font(.caption)
                        .foregroundStyle(BeetTheme.secondaryText(appearance))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(BeetTheme.secondaryText(appearance))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(BeetTheme.surface(appearance), in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(BeetTheme.line(appearance)) }
        .accessibilityLabel("Model, \(selected?.name ?? "none chosen")")
        .accessibilityHint("Opens the searchable model list")
    }
}
