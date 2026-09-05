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
                                    Text("\(group.title) · \(group.models.count)")
                                }
                                .remoteListRow()
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
        RemoteSelectionRow(
            title: model.name,
            subtitle: model.detail,
            isSelected: selectedModelID == model.id) {
                selectedModelID = model.id
                onSelect(model)
                dismiss()
            }
    }
}
