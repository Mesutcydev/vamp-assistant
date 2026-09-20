import Foundation

/// HTTP seam for the TypeSafe client. Tests inject a stub; the app uses
/// URLSession. One method, so a fake is trivial and no test ever hits the
/// network.
protocol TypeSafeTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: TypeSafeTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TypeSafeError.invalidResponse("non-HTTP response")
        }
        return (data, http)
    }
}

/// Minimal client for TypeSafe's System One endpoint (`POST /v1/systemone`).
///
/// TypeSafe is NOT an OpenAI-compatible chat API: there is no message list and
/// no generated text — you send `state` plus typed `questions` and get
/// structured `answers` back, so it can never be a chat provider in the model
/// picker. This client is deliberately small: one evaluate call, one models
/// call, retries with backoff for the statuses the API documents as retryable
/// (429 / 529 / transient 503, honouring `retry-after`), and a hard timeout so
/// a guardrail check can never stall the agent loop.
struct TypeSafeClient: Sendable {

    static let defaultBaseURL = URL(string: "https://api.typesafe.ai")!

    /// Versioned id, pinned deliberately: the `jev-latest` alias has served
    /// transient `503 model_unavailable` responses while the same build
    /// answered under its versioned id moments later. The response's `model`
    /// field reports what actually answered.
    static let defaultModel = "jev-1.13.0"
    static let knownModels = ["jev-1.13.0", "jev-latest", "jev-preview"]

    let apiKey: String
    let model: String
    let baseURL: URL
    let timeout: TimeInterval
    let maxAttempts: Int
    let transport: any TypeSafeTransport

    init(
        apiKey: String,
        model: String = TypeSafeClient.defaultModel,
        baseURL: URL = TypeSafeClient.defaultBaseURL,
        timeout: TimeInterval = 20,
        maxAttempts: Int = 3,
        transport: any TypeSafeTransport = URLSessionTransport()
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.timeout = timeout
        self.maxAttempts = max(1, maxAttempts)
        self.transport = transport
    }

    // MARK: Requests

    /// Evaluates `state` against every question in ONE call. Question ids are
    /// chosen by the caller and come back keyed the same way.
    func evaluate(state: String, questions: [String: TypeSafeQuestion]) async throws -> TypeSafeEvaluation {
        guard !questions.isEmpty else {
            throw TypeSafeError.invalidResponse("no questions")
        }
        var mapped: [String: Any] = [:]
        for (id, question) in questions {
            mapped[id] = question.jsonObject
        }
        let data = try await send(
            path: "/v1/systemone",
            body: ["state": state, "model": model, "questions": mapped])
        return try Self.parseEvaluation(data)
    }

    /// Models this account may request — doubles as the API-key check.
    func listModels() async throws -> [String] {
        let data = try await send(path: "/v1/models", body: nil)
        return try Self.parseModels(data)
    }

    // MARK: Transport

    private func send(path: String, body: [String: Any]?) async throws -> Data {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TypeSafeError.missingKey
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await transport.send(request)
                switch response.statusCode {
                case 200..<300:
                    return data
                case 401, 403:
                    throw TypeSafeError.rejected(Self.message(in: data) ?? "unauthorized")
                case 429:
                    throw TypeSafeError.rateLimited(retryAfter: Self.retryAfter(response))
                case 529:
                    throw TypeSafeError.overloaded(Self.message(in: data) ?? "too many requests")
                case 503:
                    throw TypeSafeError.unavailable(Self.message(in: data) ?? "service unavailable")
                case 422:
                    throw TypeSafeError.invalidResponse(Self.message(in: data) ?? "request rejected")
                default:
                    throw TypeSafeError.invalidResponse("HTTP \(response.statusCode)")
                }
            } catch let error as TypeSafeError {
                guard error.isRetryable, attempt < maxAttempts else { throw error }
                try? await Task.sleep(for: .seconds(Self.backoff(attempt: attempt, error: error)))
            } catch {
                let wrapped = TypeSafeError.transport(error.localizedDescription)
                guard attempt < maxAttempts else { throw wrapped }
                try? await Task.sleep(for: .seconds(Self.backoff(attempt: attempt, error: wrapped)))
            }
        }
    }

    /// Exponential backoff, honouring `retry-after` when the API sends one.
    static func backoff(attempt: Int, error: TypeSafeError) -> TimeInterval {
        if case .rateLimited(let retryAfter) = error, let retryAfter, retryAfter >= 0 {
            return min(retryAfter, 10)
        }
        return min(0.5 * pow(2, Double(attempt - 1)), 4)
    }

    // MARK: Parsing

    /// Parses an evaluation response. Total: anything malformed throws, never
    /// crashes; an unreadable answer is reported instead of silently dropped.
    static func parseEvaluation(_ data: Data) throws -> TypeSafeEvaluation {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TypeSafeError.invalidResponse("not a JSON object")
        }
        guard let rawAnswers = root["answers"] as? [String: Any] else {
            throw TypeSafeError.invalidResponse("no answers in response")
        }
        var answers: [String: TypeSafeAnswer] = [:]
        for (id, raw) in rawAnswers {
            guard let object = raw as? [String: Any], let answer = parseAnswer(object) else {
                throw TypeSafeError.invalidResponse("unreadable answer '\(id)'")
            }
            answers[id] = answer
        }
        let usage = root["usage"] as? [String: Any]
        return TypeSafeEvaluation(
            model: root["model"] as? String ?? "",
            answers: answers,
            inputTokens: number(usage?["input_tokens"]).map(Int.init) ?? 0,
            outputTokens: number(usage?["output_tokens"]).map(Int.init) ?? 0)
    }

    static func parseAnswer(_ object: [String: Any]) -> TypeSafeAnswer? {
        switch object["type"] as? String {
        case "noul":
            guard let probability = number(object["noul"]) else { return nil }
            return TypeSafeAnswer(value: .noul(probability))
        case "choice":
            guard let choice = object["choice"] as? String else { return nil }
            return TypeSafeAnswer(value: .choice(
                choice,
                probabilities: probabilities(object["probabilities"]),
                confidence: number(object["confidence"]) ?? 0))
        case "score":
            guard let rating = number(object["score"]) else { return nil }
            var legend: [String: String] = [:]
            if let raw = object["legend"] as? [String: Any] {
                for (key, value) in raw {
                    if let text = value as? String { legend[key] = text }
                }
            }
            return TypeSafeAnswer(value: .score(
                rating,
                legend: legend,
                probabilities: probabilities(object["probabilities"]),
                confidence: number(object["confidence"]) ?? 0))
        default:
            return nil
        }
    }

    static func parseModels(_ data: Data) throws -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw TypeSafeError.invalidResponse("no model list in response")
        }
        return models.compactMap { $0["name"] as? String }
    }

    /// JSON numbers bridge to NSNumber, not Double/Int directly.
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func probabilities(_ value: Any?) -> [String: Double] {
        guard let raw = value as? [String: Any] else { return [:] }
        var result: [String: Double] = [:]
        for (key, value) in raw {
            if let probability = number(value) { result[key] = probability }
        }
        return result
    }

    /// Error payloads are `{"detail": {"error_type": …, "message": …}}`.
    static func message(in data: Data) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = root["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let detail = root["detail"] as? String { return detail }
            if let message = root["message"] as? String { return message }
        }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "retry-after") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
