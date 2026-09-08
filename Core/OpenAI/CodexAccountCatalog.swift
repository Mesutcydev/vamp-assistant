import Foundation

/// Curated ChatGPT-account models that Codex's live `model/list` can omit.
/// GPT-6 Astra is the current flagship; Codex has been shipping it as hidden
/// or not yet in older CLI catalogs, which made the picker look stale.
enum CodexAccountCatalog {
    static let astraID = "gpt-6-astra"
    static let astraProID = "gpt-6-astra-pro"
    static let astraReasoningEfforts = ["low", "medium", "high", "xhigh", "max"]

    static let presets: [CodexModelProfile] = [
        CodexModelProfile(
            id: astraID,
            displayName: "GPT-6 Astra",
            description: "Latest ChatGPT model · 1.05M context",
            defaultReasoningEffort: "high",
            supportedReasoningEfforts: astraReasoningEfforts,
            inputModalities: ["text", "image"],
            isDefault: true,
            hidden: false),
        CodexModelProfile(
            id: astraProID,
            displayName: "GPT-6 Astra Pro",
            description: "Higher-effort Astra for Pro, Business, and Enterprise",
            defaultReasoningEffort: "xhigh",
            supportedReasoningEfforts: astraReasoningEfforts,
            inputModalities: ["text", "image"],
            isDefault: false,
            hidden: false),
    ]

    static func isLatest(modelID: String) -> Bool {
        let id = bareModelID(modelID).lowercased()
        return id.contains("gpt-6-astra") || id == "astra"
    }

    static func defaultReasoningEffort(for modelID: String) -> String? {
        let id = bareModelID(modelID).lowercased()
        if id.contains("astra-pro") { return "xhigh" }
        if isLatest(modelID: modelID) { return "high" }
        return nil
    }

    static func bareModelID(_ modelID: String) -> String {
        modelID.split(separator: "|").last.map(String.init) ?? modelID
    }

    static func merging(live: [CodexModelProfile]) -> [CodexModelProfile] {
        var byID: [String: CodexModelProfile] = [:]
        for preset in presets {
            byID[preset.id] = preset
        }
        for model in live {
            if isLatest(modelID: model.id), let preset = byID[model.id] {
                byID[model.id] = enrich(live: model, with: preset)
            } else {
                byID[model.id] = model
            }
        }
        return sorted(Array(byID.values))
    }

    static func sorted(_ models: [CodexModelProfile]) -> [CodexModelProfile] {
        models.sorted { lhs, rhs in
            let leftLatest = isLatest(modelID: lhs.id)
            let rightLatest = isLatest(modelID: rhs.id)
            if leftLatest != rightLatest { return leftLatest }
            if leftLatest && rightLatest {
                return latestRank(lhs.id) < latestRank(rhs.id)
            }
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.hidden != rhs.hidden { return !lhs.hidden }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func enrich(live: CodexModelProfile, with preset: CodexModelProfile) -> CodexModelProfile {
        let displayName = live.displayName == live.id || live.displayName.isEmpty
            ? preset.displayName : live.displayName
        return CodexModelProfile(
            id: live.id,
            displayName: displayName,
            description: live.description.isEmpty ? preset.description : live.description,
            defaultReasoningEffort: live.defaultReasoningEffort ?? preset.defaultReasoningEffort,
            supportedReasoningEfforts: live.supportedReasoningEfforts.isEmpty
                ? preset.supportedReasoningEfforts : live.supportedReasoningEfforts,
            inputModalities: live.inputModalities.isEmpty ? preset.inputModalities : live.inputModalities,
            isDefault: live.isDefault || preset.isDefault,
            hidden: false)
    }

    private static func latestRank(_ modelID: String) -> Int {
        let id = bareModelID(modelID).lowercased()
        if id == astraID { return 0 }
        if id.contains("astra-pro") { return 1 }
        if id.contains("gpt-6-astra") { return 2 }
        return 3
    }
}
