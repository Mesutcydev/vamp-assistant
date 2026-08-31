import Foundation
import XCTest
@testable import BeetCode

final class TinyFishSearchTests: XCTestCase {
    override func tearDown() {
        TinyFishSearchCredentialStore.delete()
        TinyFishSearchCredentialStore.resetCacheForTesting()
        super.tearDown()
    }

    func testCredentialStoreRoundTripIsCachedAndRemovable() {
        TinyFishSearchCredentialStore.delete()
        TinyFishSearchCredentialStore.resetCacheForTesting()
        XCTAssertTrue(TinyFishSearchCredentialStore.save("  tf_test_key  "))
        XCTAssertEqual(TinyFishSearchCredentialStore.apiKey(), "tf_test_key")
        XCTAssertTrue(TinyFishSearchCredentialStore.isConfigured)

        TinyFishSearchCredentialStore.delete()
        XCTAssertNil(TinyFishSearchCredentialStore.apiKey())
        XCTAssertFalse(TinyFishSearchCredentialStore.isConfigured)
    }

    func testOptionsEncodeTinyFishFilters() throws {
        let call = ParsedToolCall(
            name: "web_search",
            arguments: .object([
                "query": .string("Swift 6 concurrency"),
                "purpose": .string("find the official migration guidance"),
                "location": .string("US"),
                "language": .string("en"),
                "include_domains": .array([.string("swift.org"), .string("developer.apple.com")]),
                "recency_minutes": .number(10_080),
                "domain_type": .string("web"),
                "page": .number(1),
                "max_results": .number(5),
            ]),
            index: 0)

        let options = try TinyFishSearchClient.options(from: call)
        let url = try TinyFishSearchClient.makeURL(options: options)
        let items = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["query"], "Swift 6 concurrency")
        XCTAssertEqual(items["purpose"], "find the official migration guidance")
        XCTAssertEqual(items["location"], "US")
        XCTAssertEqual(items["language"], "en")
        XCTAssertEqual(items["include_domains"], "swift.org,developer.apple.com")
        XCTAssertEqual(items["recency_minutes"], "10080")
        XCTAssertEqual(items["page"], "1")
        XCTAssertNil(items["max_results"], "max_results is a local output limit; TinyFish does not expose it as a request parameter")
        XCTAssertNil(items["domain_type"], "web is the API default and need not be sent")
    }

    func testResearchPaperFiltersRequireResearchDomain() throws {
        let call = ParsedToolCall(
            name: "web_search",
            arguments: .object([
                "query": .string("agent orchestration"),
                "domain_type": .string("research_paper"),
                "pub_year_min": .number(2020),
                "pub_year_max": .number(2026),
            ]),
            index: 0)
        let options = try TinyFishSearchClient.options(from: call)
        XCTAssertEqual(options.domainType, "research_paper")
        XCTAssertEqual(options.publicationYearMinimum, 2020)
        XCTAssertEqual(options.publicationYearMaximum, 2026)

        let badCall = ParsedToolCall(
            name: "web_search",
            arguments: .object([
                "query": .string("agent orchestration"),
                "recency_minutes": .number(60),
                "after_date": .string("2026-01-01"),
            ]),
            index: 1)
        XCTAssertThrowsError(try TinyFishSearchClient.options(from: badCall)) { error in
            guard case TinyFishSearchError.invalidParameter(let message) = error else {
                return XCTFail("expected TinyFish validation error, got \(error)")
            }
            XCTAssertTrue(message.contains("recency_minutes"))
        }
    }

    func testDecodeAndRenderStructuredResults() throws {
        let data = Data(
            """
            {
              "query": "tinyfish search api",
              "total_results": 2,
              "page": 0,
              "results": [
                {
                  "position": 1,
                  "site_name": "TinyFish",
                  "title": "Search API",
                  "snippet": "Ranked sources for agents.",
                  "url": "https://docs.tinyfish.ai/search-api",
                  "publisher": "TinyFish",
                  "authors": ["TinyFish"],
                  "date": "2026-08-28",
                  "year": "2026",
                  "cited_by_count": 3,
                  "pdf_url": "https://docs.tinyfish.ai/search-api.pdf"
                },
                {
                  "title": "Second result",
                  "url": "https://example.com/second"
                },
                {
                  "snippet": "missing identity"
                }
              ]
            }
            """.utf8)

        let response = try TinyFishSearchClient.decodeResponse(data)
        XCTAssertEqual(response.query, "tinyfish search api")
        XCTAssertEqual(response.totalResults, 2)
        XCTAssertEqual(response.results.count, 2)
        XCTAssertEqual(response.results[0].year, 2026)
        XCTAssertEqual(response.results[0].authors, ["TinyFish"])

        let rendered = TinyFishSearchClient.render(response, maxResults: 1)
        XCTAssertTrue(rendered.contains("Search API"))
        XCTAssertTrue(rendered.contains("https://docs.tinyfish.ai/search-api"))
        XCTAssertTrue(rendered.contains("Ranked sources for agents."))
        XCTAssertFalse(rendered.contains("Second result"))
        XCTAssertTrue(rendered.contains("untrusted web content"))
    }

    @MainActor
    func testSearchIsAvailableInAssistantModeAndPromptGuidance() {
        XCTAssertTrue(PromptBuilder.isChatOnlyTool("web_search"))
        let tools = AgentSessionController.sessionTools(
            computerControlEnabled: false,
            chatOnly: true)
        XCTAssertTrue(tools.contains { $0.name == "web_search" })
        let guidance = PromptBuilder.capabilityGuidance(
            tools: [TinyFishSearchTool(), WebFetchTool()]) ?? ""
        XCTAssertTrue(guidance.contains("web_search"))
        XCTAssertTrue(guidance.contains("web_fetch"))
        XCTAssertTrue(guidance.contains("ranked sources"))
    }
}
