import Foundation

/// One typed System One question. TypeSafe's three primitives map 1:1 onto
/// the endpoint's `type` field: a noul is a yes/no question answered with the
/// probability of "yes", a choice picks one option from a rubric, and a score
/// rates the state against ordered levels. Every question is evaluated
/// independently and in parallel, so batching is the cheap path — each check
/// in this app asks all of its questions in ONE call.
enum TypeSafeQuestion: Sendable, Equatable {
    case noul(instructions: String, trueMeans: String? = nil, falseMeans: String? = nil)
    case choice(instructions: String, criteria: [String: String?])
    case score(instructions: String, criteria: [String])

    var typeName: String {
        switch self {
        case .noul: "noul"
        case .choice: "choice"
        case .score: "score"
        }
    }

    /// JSON body for one question, as a Foundation object.
    var jsonObject: [String: Any] {
        switch self {
        case .noul(let instructions, let trueMeans, let falseMeans):
            var object: [String: Any] = ["type": typeName, "instructions": instructions]
            var criteria: [String: Any] = [:]
            if let trueMeans { criteria["true"] = trueMeans }
            if let falseMeans { criteria["false"] = falseMeans }
            if !criteria.isEmpty { object["criteria"] = criteria }
            return object
        case .choice(let instructions, let criteria):
            var options: [String: Any] = [:]
            for (option, rubric) in criteria {
                options[option] = rubric ?? NSNull()
            }
            return ["type": typeName, "instructions": instructions, "criteria": options]
        case .score(let instructions, let criteria):
            return ["type": typeName, "instructions": instructions, "criteria": criteria]
        }
    }
}

/// One typed answer. Choice and Score answers carry a `confidence` derived
/// from the answer's probability distribution: the label says *what*, the
/// confidence says *whether to act on it*.
struct TypeSafeAnswer: Sendable, Equatable {
    enum Value: Sendable, Equatable {
        case noul(Double)
        case choice(String, probabilities: [String: Double], confidence: Double)
        case score(Double, legend: [String: String], probabilities: [String: Double], confidence: Double)
    }

    let value: Value

    /// Probability the answer is "yes" (noul answers only).
    var noul: Double? {
        if case .noul(let probability) = value { return probability }
        return nil
    }

    /// The winning option (choice answers only).
    var choice: String? {
        if case .choice(let option, _, _) = value { return option }
        return nil
    }

    /// The probability-weighted rating (score answers only).
    var rating: Double? {
        if case .score(let rating, _, _, _) = value { return rating }
        return nil
    }

    var confidence: Double? {
        switch value {
        case .noul: nil
        case .choice(_, _, let confidence): confidence
        case .score(_, _, _, let confidence): confidence
        }
    }
}

/// One evaluation response: the model that answered, one answer per question
/// id, and token usage (TypeSafe bills input tokens; output tokens are free).
struct TypeSafeEvaluation: Sendable, Equatable {
    let model: String
    let answers: [String: TypeSafeAnswer]
    let inputTokens: Int
    let outputTokens: Int
}

/// TypeSafe API failures, classified so callers can retry only what is worth
/// retrying and degrade cleanly on everything else. The guardrail path treats
/// every failure identically: no verdict, existing behavior unchanged.
enum TypeSafeError: Error, LocalizedError, Equatable {
    case missingKey
    case rejected(String)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded(String)
    case unavailable(String)
    case transport(String)
    case invalidResponse(String)

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .unavailable, .transport: true
        case .missingKey, .rejected, .invalidResponse: false
        }
    }

    /// One-line label for transcripts and settings status text.
    var label: String {
        switch self {
        case .missingKey: "no API key"
        case .rejected: "key rejected"
        case .rateLimited: "rate limited"
        case .overloaded: "service overloaded"
        case .unavailable: "model unavailable"
        case .transport: "network error"
        case .invalidResponse: "unexpected response"
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add a TypeSafe API key in Settings → Providers to use guardrails."
        case .rejected(let message):
            return "TypeSafe rejected this API key: \(message)"
        case .rateLimited(let retryAfter):
            let suffix = retryAfter.map { " — retry after \(Int($0))s" } ?? ""
            return "TypeSafe rate limit reached\(suffix)."
        case .overloaded(let message):
            return "TypeSafe is overloaded: \(message)"
        case .unavailable(let message):
            return "TypeSafe reported the model unavailable: \(message)"
        case .transport(let message):
            return "TypeSafe request failed: \(message)"
        case .invalidResponse(let message):
            return "Unexpected response from TypeSafe: \(message)"
        }
    }
}
