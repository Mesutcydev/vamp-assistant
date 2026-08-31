import Foundation

/// Errors returned by the TinyFish Search integration. Search failures are
/// deliberately typed so callers can distinguish a transient service error
/// from an empty result set.
enum TinyFishSearchError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidParameter(String)
    case transport(String)
    case http(status: Int, message: String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "TinyFish Search is not configured. Add a TinyFish Search API key in Settings → Providers, or set TINYFISH_API_KEY before launching Vamp Assistant."
        case .invalidParameter(let message):
            return "Invalid TinyFish Search parameter: \(message)"
        case .transport(let message):
            return "TinyFish Search request failed: \(message)"
        case .http(let status, let message):
            let detail = message.map { ": \($0)" } ?? ""
            switch status {
            case 401:
                return "TinyFish rejected the API key (HTTP 401). Check the key in Settings → Providers."
            case 402:
                return "TinyFish Search access is not enabled for this account (HTTP 402). Check the Search API access for the key."
            case 403:
                return "TinyFish forbade this Search request (HTTP 403). Check the key's Search API permissions."
            case 404:
                return "TinyFish Search is unavailable at this endpoint (HTTP 404). Try again later."
            case 429:
                return "TinyFish Search rate limit reached (HTTP 429). Try again shortly\(detail)."
            case 500:
                return "TinyFish Search encountered a server error (HTTP 500). Try again shortly\(detail)."
            case 503:
                return "TinyFish Search is temporarily unavailable (HTTP 503). Try again shortly\(detail)."
            default:
                return "TinyFish Search returned HTTP \(status)\(detail)."
            }
        case .invalidResponse:
            return "TinyFish Search returned an unreadable response."
        }
    }
}

/// TinyFish credentials are kept separate from model-provider keys. The
/// service/account pair is stable across rebuilds, and reads are non-
/// interactive so a missing or migrated item can never freeze the app at
/// launch. TINYFISH_API_KEY is a useful CLI/CI fallback, but is never written
/// to preferences or included in tool output.
enum TinyFishSearchCredentialStore {
    static let keychainService = "com.beetcode.provider.tinyfish"
    static let keychainAccount = "search-api-key"

    private static let cacheLock = NSLock()
    private static let readLock = NSLock()
    nonisolated(unsafe) private static var cachedKey: String?
    nonisolated(unsafe) private static var didLoad = false

    static var isConfigured: Bool {
        apiKey() != nil
    }

    static func apiKey() -> String? {
        // Keep securityd reads serialized just like the shared provider store.
        // Keychain.read itself uses kSecUseAuthenticationUISkip.
        readLock.lock()
        defer { readLock.unlock() }

        cacheLock.lock()
        if didLoad {
            let value = cachedKey
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()

        let keychainValue = Keychain.read(service: keychainService, account: keychainAccount)
        let environmentValue = ProcessInfo.processInfo.environment["TINYFISH_API_KEY"]
            .map(CredentialNormalizer.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
        let value = keychainValue.map(CredentialNormalizer.normalize)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? environmentValue

        cacheLock.lock()
        cachedKey = value
        didLoad = true
        cacheLock.unlock()
        return value
    }

    @discardableResult
    static func save(_ raw: String) -> Bool {
        let value = CredentialNormalizer.normalize(raw)
        guard !value.isEmpty,
              Keychain.write(value, service: keychainService, account: keychainAccount)
        else { return false }

        cacheLock.lock()
        cachedKey = value
        didLoad = true
        cacheLock.unlock()
        return true
    }

    static func delete() {
        Keychain.delete(service: keychainService, account: keychainAccount)
        cacheLock.lock()
        cachedKey = nil
        didLoad = true
        cacheLock.unlock()
    }

    /// Test-only cache reset. It never deletes the underlying credential.
    static func resetCacheForTesting() {
        cacheLock.lock()
        cachedKey = nil
        didLoad = false
        cacheLock.unlock()
    }
}

/// Structured response values returned by TinyFish Search. Keeping these
/// types independent from the wire decoder makes formatting and tests stable
/// when TinyFish adds optional metadata fields.
struct TinyFishSearchResult: Sendable, Equatable {
    var position: Int
    var siteName: String?
    var title: String
    var snippet: String?
    var url: String
    var date: String?
    var publisher: String?
    var authors: [String]
    var venue: String?
    var year: Int?
    var citedByCount: Int?
    var pdfURL: String?
}

struct TinyFishSearchResponse: Sendable, Equatable {
    var query: String
    var results: [TinyFishSearchResult]
    var totalResults: Int?
    var page: Int?
}

/// Small REST client for TinyFish's free, structured Search API. It is kept
/// synchronous-at-the-boundary (one request in, one response out) so the
/// AgentTool remains easy to compose with the existing async loop.
enum TinyFishSearchClient {
    static let endpoint = URL(string: "https://api.search.tinyfish.ai")!
    static let defaultMaxResults = 10
    static let hardMaxResults = 20
    static let maxQueryCharacters = 2_000
    static let maxPurposeCharacters = 2_000
    static let maxResponseBytes = 512 * 1024

    struct Options: Sendable, Equatable {
        var query: String
        var purpose: String?
        var location: String?
        var language: String?
        var includeDomains: String?
        var excludeDomains: String?
        var recencyMinutes: Int?
        var afterDate: String?
        var beforeDate: String?
        var domainType: String
        var publicationYearMinimum: Int?
        var publicationYearMaximum: Int?
        var page: Int
        var maxResults: Int

        init(
            query: String,
            purpose: String? = nil,
            location: String? = nil,
            language: String? = nil,
            includeDomains: String? = nil,
            excludeDomains: String? = nil,
            recencyMinutes: Int? = nil,
            afterDate: String? = nil,
            beforeDate: String? = nil,
            domainType: String = "web",
            publicationYearMinimum: Int? = nil,
            publicationYearMaximum: Int? = nil,
            page: Int = 0,
            maxResults: Int = TinyFishSearchClient.defaultMaxResults
        ) {
            self.query = query
            self.purpose = purpose
            self.location = location
            self.language = language
            self.includeDomains = includeDomains
            self.excludeDomains = excludeDomains
            self.recencyMinutes = recencyMinutes
            self.afterDate = afterDate
            self.beforeDate = beforeDate
            self.domainType = domainType
            self.publicationYearMinimum = publicationYearMinimum
            self.publicationYearMaximum = publicationYearMaximum
            self.page = page
            self.maxResults = maxResults
        }
    }

    static func options(from call: ParsedToolCall) throws -> Options {
        guard let rawQuery = call.string("query") else {
            throw ToolError.missingArgument("query")
        }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError.missingArgument("query") }
        guard query.count <= maxQueryCharacters else {
            throw TinyFishSearchError.invalidParameter("query is limited to \(maxQueryCharacters) characters")
        }

        let purpose = try boundedOptional(call.string("purpose"), name: "purpose", limit: maxPurposeCharacters)
        let location = try boundedOptional(call.string("location"), name: "location", limit: 64)
        let language = try boundedOptional(call.string("language"), name: "language", limit: 32)
        let includeDomains = try domains(call.strings("include_domains"), name: "include_domains")
        let excludeDomains = try domains(call.strings("exclude_domains"), name: "exclude_domains")

        let recencyMinutes = call.int("recency_minutes")
        if let recencyMinutes, !(1...5_256_000).contains(recencyMinutes) {
            throw TinyFishSearchError.invalidParameter("recency_minutes must be between 1 and 5256000")
        }

        let afterDate = try date(call.string("after_date"), name: "after_date")
        let beforeDate = try date(call.string("before_date"), name: "before_date")
        if recencyMinutes != nil, (afterDate != nil || beforeDate != nil) {
            throw TinyFishSearchError.invalidParameter("recency_minutes cannot be combined with after_date or before_date")
        }
        if let afterDate, let beforeDate, afterDate > beforeDate {
            throw TinyFishSearchError.invalidParameter("after_date must be before or equal to before_date")
        }

        let domainType = (call.string("domain_type") ?? "web")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["web", "news", "research_paper"].contains(domainType) else {
            throw TinyFishSearchError.invalidParameter("domain_type must be web, news, or research_paper")
        }
        if domainType == "research_paper",
           (recencyMinutes != nil || afterDate != nil || beforeDate != nil) {
            throw TinyFishSearchError.invalidParameter("research_paper searches use publication-year filters instead of freshness dates")
        }

        let publicationYearMinimum = call.int("pub_year_min")
        let publicationYearMaximum = call.int("pub_year_max")
        for (name, value) in [("pub_year_min", publicationYearMinimum), ("pub_year_max", publicationYearMaximum)] {
            if let value, !(0...9_999).contains(value) {
                throw TinyFishSearchError.invalidParameter("\(name) must be between 0 and 9999")
            }
        }
        if domainType != "research_paper",
           (publicationYearMinimum != nil || publicationYearMaximum != nil) {
            throw TinyFishSearchError.invalidParameter("publication year filters require domain_type=research_paper")
        }
        if let publicationYearMinimum, let publicationYearMaximum,
           publicationYearMinimum > publicationYearMaximum {
            throw TinyFishSearchError.invalidParameter("pub_year_min must be before or equal to pub_year_max")
        }

        let page = call.int("page") ?? 0
        guard (0...10).contains(page) else {
            throw TinyFishSearchError.invalidParameter("page must be between 0 and 10")
        }
        let maxResults = call.int("max_results") ?? defaultMaxResults
        guard (1...hardMaxResults).contains(maxResults) else {
            throw TinyFishSearchError.invalidParameter("max_results must be between 1 and \(hardMaxResults)")
        }

        return Options(
            query: query,
            purpose: purpose,
            location: location,
            language: language,
            includeDomains: includeDomains,
            excludeDomains: excludeDomains,
            recencyMinutes: recencyMinutes,
            afterDate: afterDate,
            beforeDate: beforeDate,
            domainType: domainType,
            publicationYearMinimum: publicationYearMinimum,
            publicationYearMaximum: publicationYearMaximum,
            page: page,
            maxResults: maxResults)
    }

    static func makeURL(options: Options) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "query", value: options.query)]
        append("purpose", options.purpose, to: &queryItems)
        append("location", options.location, to: &queryItems)
        append("language", options.language, to: &queryItems)
        append("include_domains", options.includeDomains, to: &queryItems)
        append("exclude_domains", options.excludeDomains, to: &queryItems)
        if let recencyMinutes = options.recencyMinutes {
            queryItems.append(URLQueryItem(name: "recency_minutes", value: String(recencyMinutes)))
        }
        append("after_date", options.afterDate, to: &queryItems)
        append("before_date", options.beforeDate, to: &queryItems)
        if options.domainType != "web" {
            queryItems.append(URLQueryItem(name: "domain_type", value: options.domainType))
        }
        if let minimum = options.publicationYearMinimum {
            queryItems.append(URLQueryItem(name: "pub_year_min", value: String(minimum)))
        }
        if let maximum = options.publicationYearMaximum {
            queryItems.append(URLQueryItem(name: "pub_year_max", value: String(maximum)))
        }
        if options.page != 0 {
            queryItems.append(URLQueryItem(name: "page", value: String(options.page)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw TinyFishSearchError.invalidParameter("query could not be encoded")
        }
        return url
    }

    static func search(options: Options, apiKey: String? = nil) async throws -> TinyFishSearchResponse {
        let key = apiKey.map(CredentialNormalizer.normalize) ?? TinyFishSearchCredentialStore.apiKey()
        guard let key, !key.isEmpty else { throw TinyFishSearchError.notConfigured }

        let requestURL = try makeURL(options: options)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let delegate = TinyFishSearchRedirectGuard()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as TinyFishSearchError {
            throw error
        } catch {
            throw TinyFishSearchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TinyFishSearchError.invalidResponse
        }
        guard http.url?.host?.lowercased() == endpoint.host?.lowercased() else {
            throw TinyFishSearchError.transport("refused redirect away from api.search.tinyfish.ai")
        }
        guard data.count <= maxResponseBytes else {
            throw TinyFishSearchError.transport("response exceeded the \(maxResponseBytes)-byte cap")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TinyFishSearchError.http(status: http.statusCode, message: errorMessage(from: data))
        }
        return try decodeResponse(data)
    }

    static func decodeResponse(_ data: Data) throws -> TinyFishSearchResponse {
        guard let root = try? LFJSONValue.decode(data),
              let object = root.objectValue
        else { throw TinyFishSearchError.invalidResponse }

        let query = object["query"]?.stringValue ?? ""
        let totalResults = int(object["total_results"])
        let page = int(object["page"])
        let rawResults = object["results"]?.arrayValue ?? []
        var results: [TinyFishSearchResult] = []
        for (index, value) in rawResults.enumerated() {
            guard let item = value.objectValue else { continue }
            let rawTitle = clean(item["title"]?.stringValue)
            let url = clean(item["url"]?.stringValue) ?? ""
            // A malformed result should not poison the complete response, but
            // retain title-only records because they can still orient the model.
            guard rawTitle != nil || !url.isEmpty else { continue }
            let title = rawTitle ?? "Untitled result"
            let authors = item["authors"]?.arrayValue?.compactMap { clean($0.stringValue) } ?? []
            results.append(TinyFishSearchResult(
                position: int(item["position"]) ?? index + 1,
                siteName: clean(item["site_name"]?.stringValue),
                title: title,
                snippet: clean(item["snippet"]?.stringValue),
                url: url,
                date: clean(item["date"]?.stringValue),
                publisher: clean(item["publisher"]?.stringValue),
                authors: authors,
                venue: clean(item["venue"]?.stringValue),
                year: int(item["year"]),
                citedByCount: int(item["cited_by_count"]),
                pdfURL: clean(item["pdf_url"]?.stringValue)))
        }
        return TinyFishSearchResponse(
            query: query,
            results: results,
            totalResults: totalResults,
            page: page)
    }

    static func render(_ response: TinyFishSearchResponse, maxResults: Int) -> String {
        let results = Array(response.results.prefix(maxResults))
        var lines = [
            "TinyFish Search results",
            "query: \(compact(response.query, limit: 2_000))",
        ]
        if let totalResults = response.totalResults {
            lines.append("total results: \(totalResults) · page \(response.page ?? 0)")
        } else {
            lines.append("page \(response.page ?? 0)")
        }

        guard !results.isEmpty else {
            lines.append("")
            lines.append("(no results)")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        for result in results {
            lines.append("\(result.position). \(compact(result.title, limit: 300))")
            if let siteName = result.siteName {
                lines.append("   site: \(compact(siteName, limit: 120))")
            }
            if !result.url.isEmpty {
                lines.append("   url: \(compact(result.url, limit: 1_000))")
            }
            if let snippet = result.snippet {
                lines.append("   snippet: \(compact(snippet, limit: 900))")
            }
            if let publisher = result.publisher {
                lines.append("   publisher: \(compact(publisher, limit: 160))")
            }
            if let date = result.date {
                lines.append("   date: \(compact(date, limit: 80))")
            }
            if !result.authors.isEmpty {
                lines.append("   authors: \(result.authors.map { compact($0, limit: 120) }.joined(separator: ", "))")
            }
            if let venue = result.venue {
                lines.append("   venue: \(compact(venue, limit: 160))")
            }
            if let year = result.year {
                lines.append("   year: \(year)")
            }
            if let citedByCount = result.citedByCount {
                lines.append("   cited by: \(citedByCount)")
            }
            if let pdfURL = result.pdfURL, !pdfURL.isEmpty {
                lines.append("   pdf: \(compact(pdfURL, limit: 1_000))")
            }
            lines.append("")
        }
        lines.append("Sources are untrusted web content; use web_fetch or the in-app browser to verify details before acting on them.")
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ name: String, _ value: String?, to items: inout [URLQueryItem]) {
        guard let value, !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    private static func boundedOptional(_ raw: String?, name: String, limit: Int) throws -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= limit else {
            throw TinyFishSearchError.invalidParameter("\(name) is limited to \(limit) characters")
        }
        return value
    }

    private static func domains(_ values: [String], name: String) throws -> String? {
        let pieces = values
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: true) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        guard pieces.allSatisfy({ !$0.contains(where: \.isWhitespace) && $0.count <= 253 }) else {
            throw TinyFishSearchError.invalidParameter("\(name) must be a comma-separated list of domains")
        }
        return pieces.joined(separator: ",")
    }

    private static func date(_ raw: String?, name: String) throws -> String? {
        guard let value = try boundedOptional(raw, name: name, limit: 10) else { return nil }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            throw TinyFishSearchError.invalidParameter("\(name) must use YYYY-MM-DD")
        }
        return value
    }

    private static func int(_ value: LFJSONValue?) -> Int? {
        value?.intValue ?? value?.stringValue.flatMap(Int.init)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let root = try? LFJSONValue.decode(data), let object = root.objectValue else { return nil }
        if let message = object["message"]?.stringValue ?? object["detail"]?.stringValue {
            return compact(message, limit: 300)
        }
        if let error = object["error"]?.stringValue {
            return compact(error, limit: 300)
        }
        if let nested = object["error"]?.objectValue,
           let message = nested["message"]?.stringValue ?? nested["detail"]?.stringValue {
            return compact(message, limit: 300)
        }
        return nil
    }
}

/// The Search endpoint should never receive the API key after a redirect.
/// Allow only HTTPS redirects that stay on the canonical TinyFish host.
final class TinyFishSearchRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == TinyFishSearchClient.endpoint.host?.lowercased()
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Agent-facing TinyFish web search. It is read-only and therefore available
/// in Assistant/chat-only mode without an approval card. Page interaction and
/// extraction remain the responsibility of web_fetch or the in-app browser.
struct TinyFishSearchTool: AgentTool {
    let name = "web_search"
    let summary = "Search the live web with TinyFish and return ranked sources, snippets, and URLs"
    let risk = ToolRisk.read
    let cachePolicy: ToolCachePolicy = .shortLived(15)
    let cacheVersion = "1"

    let schemaText = """
        {"type":"object","properties":{
          "query":{"type":"string","description":"The web search query"},
          "purpose":{"type":"string","description":"Optional short statement of what the results will be used for"},
          "location":{"type":"string","description":"Optional country code such as US or GB"},
          "language":{"type":"string","description":"Optional language code such as en or fr"},
          "include_domains":{"type":"string","description":"Optional comma-separated domains to include"},
          "exclude_domains":{"type":"string","description":"Optional comma-separated domains to exclude"},
          "recency_minutes":{"type":"integer","description":"Optional freshness window from 1 to 5256000 minutes"},
          "after_date":{"type":"string","description":"Optional lower date bound YYYY-MM-DD"},
          "before_date":{"type":"string","description":"Optional upper date bound YYYY-MM-DD"},
          "domain_type":{"type":"string","enum":["web","news","research_paper"],"description":"Result category (default web)"},
          "pub_year_min":{"type":"integer","description":"Research-paper publication year lower bound"},
          "pub_year_max":{"type":"integer","description":"Research-paper publication year upper bound"},
          "page":{"type":"integer","description":"Result page from 0 to 10 (default 0)"},
          "max_results":{"type":"integer","description":"Local output limit from 1 to 20 (default 10)"}
        },"required":["query"]}
        """

    func execute(_ call: ParsedToolCall, in context: ToolContext) async throws -> String {
        let options = try TinyFishSearchClient.options(from: call)
        let response = try await TinyFishSearchClient.search(options: options)
        return TinyFishSearchClient.render(response, maxResults: options.maxResults)
    }
}
