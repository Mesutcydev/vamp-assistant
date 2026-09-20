import Foundation

/// Wire protocol used by a remote model. OpenCode deliberately exposes more
/// than one provider protocol behind the same provider/model picker, so the
/// endpoint must carry this capability instead of guessing from the URL.
enum RemoteAPIProtocol: String, Codable, Sendable, Equatable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages
    case gemini

    var label: String {
        switch self {
        case .openAIChatCompletions: "OpenAI chat"
        case .openAIResponses: "OpenAI Responses"
        case .anthropicMessages: "Anthropic Messages"
        case .gemini: "Google Gemini"
        }
    }

    /// OpenCode provider definitions identify their AI SDK package. These
    /// package names are part of the public config contract and are a more
    /// reliable signal than a model-name heuristic.
    static func inferred(
        providerID: String,
        model: String = "",
        package: String? = nil
    ) -> RemoteAPIProtocol {
        let package = package?.lowercased() ?? ""
        let provider = providerID.lowercased()
        let model = model.lowercased()

        if package.contains("anthropic") || provider == "anthropic" {
            return .anthropicMessages
        }
        if package.contains("google") || package.contains("gemini")
            || provider == "gemini" || provider.contains("vertex") {
            return .gemini
        }
        if package.contains("openai-compatible") {
            return .openAIChatCompletions
        }
        if package.contains("openai") {
            return .openAIResponses
        }

        // OpenCode Zen/Go are mixed gateways. The model-to-protocol table is
        // published per model (opencode.ai/docs/zen, /docs/go and models.dev);
        // these rules mirror it:
        //   Gemini        -> native Google protocol under /v1/models/<id>
        //   Claude/Qwen   -> Anthropic Messages (/messages)
        //   MiniMax       -> Messages on Go and for Zen's `-free` variants;
        //                    OpenAI chat completions for Zen's paid variants
        //   GPT/Codex, Grok 4.x/Build, Muse Spark -> OpenAI Responses
        //   everything else (GLM, Kimi, DeepSeek, LongCat, MiMo, Hy3, ...)
        //                    -> OpenAI chat completions
        if provider == "opencode" || provider == "opencode-go" {
            let isGo = provider == "opencode-go"
            let leaf = model.split(separator: "/").last.map(String.init) ?? model

            if leaf.hasPrefix("gemini") {
                return .gemini
            }
            if leaf.contains("claude") || leaf.contains("qwen") {
                return .anthropicMessages
            }
            if leaf.contains("minimax") {
                return isGo || leaf.contains("-free") ? .anthropicMessages : .openAIChatCompletions
            }
            if leaf.contains("gpt") || leaf.contains("codex")
                || leaf.contains("muse-spark")
                || leaf.hasPrefix("grok-4") || leaf.hasPrefix("grok-build") {
                return .openAIResponses
            }
        }

        return .openAIChatCompletions
    }
}
