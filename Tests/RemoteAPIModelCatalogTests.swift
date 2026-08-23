import XCTest
@testable import BeetCode

final class RemoteAPIModelCatalogTests: XCTestCase {

    func testConfiguredProviderPublishesEveryCatalogModel() {
        let profiles = RemoteAPIModelCatalog.profiles(
            configuredProviders: [.openAI],
            selectedModelByProvider: ["openAI": "gpt-4o"],
            savedProfiles: [],
            hasKeyForProviderID: { _ in false })

        let models = Set(profiles.map(\.model))
        XCTAssertTrue(LLMProvider.openAI.availableModels.allSatisfy(models.contains))
        XCTAssertTrue(models.contains("gpt-4o"))
        XCTAssertTrue(models.contains(LLMProvider.openAI.defaultModel))
        XCTAssertTrue(profiles.allSatisfy { $0.provider == .openAI })
        XCTAssertEqual(
            RemoteAPIModelCatalog.startModelID(for: profiles.first { $0.model == "gpt-4o" }!),
            "api|openAI|gpt-4o")
    }

    func testSavedLiveProfilesAreKeptAndNotReplacedByCatalogStubs() throws {
        let live = RemoteModelProfile(
            provider: .openAI,
            model: "gpt-5.4-preview",
            displayName: "GPT-5.4 Preview",
            contextWindow: 1_000_000,
            supportsTools: true)
        let profiles = RemoteAPIModelCatalog.profiles(
            configuredProviders: [.openAI],
            selectedModelByProvider: [:],
            savedProfiles: [live],
            hasKeyForProviderID: { _ in false })

        let preview = try XCTUnwrap(profiles.first { $0.model == "gpt-5.4-preview" })
        XCTAssertEqual(preview.displayName, "GPT-5.4 Preview")
        XCTAssertEqual(preview.contextWindow, 1_000_000)
        XCTAssertTrue(profiles.contains { $0.model == "gpt-4o-mini" })
    }

    func testKnownGatewayPublishesEveryAvailableModel() throws {
        let groq = try XCTUnwrap(KnownRemoteProvider.find("groq"))
        let profiles = RemoteAPIModelCatalog.profiles(
            configuredProviders: [],
            selectedModelByProvider: [:],
            savedProfiles: [],
            hasKeyForProviderID: { $0 == "groq" })

        let groqModels = profiles.filter { $0.providerKey == "groq" }
        XCTAssertTrue(groq.availableModels.allSatisfy { model in
            groqModels.contains { $0.model == model }
        })
        XCTAssertEqual(
            RemoteAPIModelCatalog.startModelID(for: groqModels.first { $0.model == groq.defaultModel }!),
            "api|groq|\(groq.defaultModel)")
        XCTAssertTrue(profiles.filter { $0.provider == .openAI }.isEmpty)
    }

    func testOpenCodeProfilesKeepProviderIdentity() throws {
        let imported = RemoteModelProfile(
            provider: .custom,
            model: "gpt-4o",
            providerKey: "work-gateway",
            providerDisplayName: "Work gateway",
            apiProtocol: .openAIChatCompletions,
            baseURL: "https://gateway.example/v1")
        let profiles = RemoteAPIModelCatalog.profiles(
            configuredProviders: [.openAI],
            selectedModelByProvider: [:],
            savedProfiles: [],
            hasKeyForProviderID: { _ in false },
            openCodeProfiles: [imported])

        let openAI = try XCTUnwrap(profiles.first { $0.provider == .openAI && $0.model == "gpt-4o" })
        let gateway = try XCTUnwrap(profiles.first { $0.providerKey == "work-gateway" })
        XCTAssertEqual(RemoteAPIModelCatalog.startModelID(for: openAI), "api|openAI|gpt-4o")
        XCTAssertEqual(RemoteAPIModelCatalog.startModelID(for: gateway), "api|work-gateway|gpt-4o")
        XCTAssertEqual(
            RemoteAPIModelCatalog.profile(matchingStartModelID: "api|work-gateway|gpt-4o", in: profiles)?.baseURL,
            "https://gateway.example/v1")
    }

    func testUnconfiguredProviderProfilesAreHidden() {
        let stale = RemoteModelProfile(provider: .anthropic, model: "claude-sonnet-4-5")
        let profiles = RemoteAPIModelCatalog.profiles(
            configuredProviders: [.openAI],
            selectedModelByProvider: [:],
            savedProfiles: [stale],
            hasKeyForProviderID: { _ in false })

        XCTAssertFalse(profiles.contains { $0.provider == .anthropic })
    }
}
