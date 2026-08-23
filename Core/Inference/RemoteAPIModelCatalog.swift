import Foundation

/// Shared API-model inventory for the Mac picker and remote `/api/models`.
///
/// The iOS client and the Mac composer must list the same usable models:
/// saved live `/models` profiles, each configured provider's catalog, imported
/// OpenCode definitions, and named compatible gateways that already have a key.
enum RemoteAPIModelCatalog {
    static func startModelID(for profile: RemoteModelProfile) -> String {
        "api|\(profile.providerKey ?? profile.provider.rawValue)|\(profile.model)"
    }

    static func profile(
        matchingStartModelID id: String,
        in profiles: [RemoteModelProfile]
    ) -> RemoteModelProfile? {
        profiles.first { startModelID(for: $0) == id }
    }

    static func profiles(
        configuredProviders: Set<LLMProvider>,
        selectedModelByProvider: [String: String],
        savedProfiles: [RemoteModelProfile],
        hasKeyForProviderID: (String) -> Bool,
        openCodeProfiles: [RemoteModelProfile] = []
    ) -> [RemoteModelProfile] {
        var byID: [String: RemoteModelProfile] = [:]

        func add(_ profile: RemoteModelProfile) {
            guard !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if byID[profile.id] == nil {
                byID[profile.id] = profile
            }
        }

        for profile in savedProfiles where isUsable(profile, configuredProviders: configuredProviders, hasKeyForProviderID: hasKeyForProviderID) {
            add(profile)
        }

        for provider in configuredProviders.sorted(by: { $0.displayName < $1.displayName }) {
            let selected = selectedModelByProvider[provider.rawValue]
            let models = provider.availableModels + [selected, provider.defaultModel].compactMap { $0 }
            for model in models {
                add(RemoteModelProfile(
                    provider: provider,
                    model: model,
                    supportsVision: provider.supportsVision,
                    supportsTools: true))
            }
        }

        for profile in openCodeProfiles {
            add(profile)
        }

        for provider in KnownRemoteProvider.all where hasKeyForProviderID(provider.id) {
            for model in provider.availableModels + [provider.defaultModel] {
                add(RemoteModelProfile(
                    provider: .custom,
                    model: model,
                    supportsTools: true,
                    providerKey: provider.id,
                    providerDisplayName: provider.displayName,
                    apiProtocol: provider.apiProtocol,
                    baseURL: provider.baseURL.absoluteString))
            }
        }

        return byID.values.sorted {
            if $0.displayProviderName != $1.displayProviderName {
                return $0.displayProviderName.localizedStandardCompare($1.displayProviderName) == .orderedAscending
            }
            return $0.model.localizedStandardCompare($1.model) == .orderedAscending
        }
    }

    private static func isUsable(
        _ profile: RemoteModelProfile,
        configuredProviders: Set<LLMProvider>,
        hasKeyForProviderID: (String) -> Bool
    ) -> Bool {
        if let providerKey = profile.providerKey, !providerKey.isEmpty {
            return hasKeyForProviderID(providerKey) || configuredProviders.contains(profile.provider)
        }
        return configuredProviders.contains(profile.provider)
    }
}
