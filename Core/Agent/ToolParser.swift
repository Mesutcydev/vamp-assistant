import Foundation

/// One tool call extracted from raw model output.
struct ParsedToolCall: Sendable, Equatable, Identifiable {
    let name: String
    let arguments: LFJSONValue
    let index: Int

    var id: String { "\(name)#\(index)" }

    /// Canonical JSON for execution/logging.
    var argumentsJSON: String { arguments.encoded() }

    func askUserQuestion() -> String {
        if let text = string("question") ?? string("query") ?? string("prompt")
            ?? string("text") ?? string("message"),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let text = arguments.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "Please answer."
    }

    func askUserChoices() -> [String] {
        for key in ["choices", "options", "answers"] {
            let values = strings(key).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !values.isEmpty { return values }
        }
        return []
    }

    /// Convenience accessors used by tools.
    func string(_ key: String) -> String? {
        arguments.objectValue?[key]?.stringValue
            ?? arguments.objectValue?[key]?.numberValue.map { String($0) }
    }

    func int(_ key: String) -> Int? {
        arguments.objectValue?[key]?.intValue
            ?? arguments.objectValue?[key]?.stringValue.flatMap(Int.init)
    }

    func number(_ key: String) -> Double? {
        arguments.objectValue?[key]?.numberValue
            ?? arguments.objectValue?[key]?.stringValue.flatMap(Double.init)
    }

    func bool(_ key: String) -> Bool? {
        arguments.objectValue?[key]?.boolValue
            ?? arguments.objectValue?[key]?.stringValue.flatMap { $0.lowercased() == "true" ? true : ($0.lowercased() == "false" ? false : nil) }
    }

    /// String arrays (e.g. modifier lists). A bare string is treated as a
    /// one-element array — models often emit `"modifiers": "cmd"`.
    func strings(_ key: String) -> [String] {
        if let array = arguments.objectValue?[key]?.arrayValue {
            return array.compactMap(\.stringValue)
        }
        if let single = arguments.objectValue?[key]?.stringValue {
            return [single]
        }
        return []
    }
}

/// Extracts tool calls from raw model text. Completely independent of the
/// inference engine — the pipeline is:
///
///     raw text → block extractor → tolerant JSON normalization → shape validation
///
/// Guided generation, when enabled later, is an optimization that makes calls
/// well-formed before they reach this parser; it is never a dependency.
///
/// Recognized formats (in priority order of appearance, all merged):
/// 1. Fenced blocks:      ```tool { "name": …, "arguments": {…} } ```
/// 2. Qwen native tags:   <tool_call>{ "name": …, "arguments": {…} }</tool_call>
/// 3. OpenAI envelopes:   { "tool_calls": [ { "function": { "name": … } } ] }
/// 4. Bare JSON objects containing a "name" key (last resort)
enum ToolParser {

    struct Candidate: Equatable {
        let range: Range<String.Index>
        let payload: String
        /// The complete wire-format container, when the payload came from a
        /// fenced block or `<tool_call>` wrapper. Parsing only needs `range`,
        /// while display cleanup must remove the wrapper as well.
        let containerRange: Range<String.Index>?
    }

    static func parse(_ text: String) -> [ParsedToolCall] {
        let candidates = collectCandidates(text)
        var calls: [ParsedToolCall] = []
        var seen = Set<String>()

        for candidate in candidates {
            for call in decodePayload(candidate.payload) where !seen.contains(call.signature) {
                seen.insert(call.signature)
                calls.append(
                    ParsedToolCall(
                        name: call.name,
                        arguments: call.arguments,
                        index: calls.count))
            }
        }
        return calls
    }

    private static func decodePayload(_ payload: String) -> [Shaped] {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = TolerantJSON.value(from: trimmed) {
            let shaped = shape(value)
            if !shaped.isEmpty { return shaped }
        }
        if let xml = xmlTaggedCall(trimmed) {
            return [xml]
        }
        // Hermes / some Qwen variants: tool name on the first line, JSON after.
        if let newline = trimmed.firstIndex(of: "\n") {
            let name = String(trimmed[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(trimmed[trimmed.index(after: newline)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isToolName(name) {
                if let value = TolerantJSON.value(from: rest) {
                    return [Shaped(name: name, arguments: coerceArguments(value))]
                }
                if let xml = xmlArguments(rest) {
                    return [Shaped(name: name, arguments: xml)]
                }
                if !rest.isEmpty {
                    return [Shaped(name: name, arguments: .string(rest))]
                }
            }
        }
        if isToolName(trimmed) {
            return [Shaped(name: trimmed, arguments: .object([:]))]
        }
        return []
    }

    private static func isToolName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    // MARK: Extraction

    private static func collectCandidates(_ text: String) -> [Candidate] {
        var candidates: [Candidate] = []

        // 1. Fenced code blocks whose info string mentions tool/json, or whose
        //    body starts with '{'.
        if let regex = try? NSRegularExpression(pattern: "```[a-zA-Z0-9_-]*[ \\t]*\\n?([\\s\\S]*?)```") {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let payloadRange = Range(match.range(at: 1), in: text)
                else { continue }
                let payload = text[payloadRange].trimmingCharacters(in: .whitespacesAndNewlines)
                guard payload.hasPrefix("{") else { continue }
                candidates.append(Candidate(
                    range: payloadRange,
                    payload: payload,
                    containerRange: Range(match.range, in: text)))
            }
        }

        // 2. <tool_call> XML wrappers (Qwen).
        if let regex = try? NSRegularExpression(pattern: #"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                if let payloadRange = Range(match.range(at: 1), in: text) {
                    candidates.append(Candidate(
                        range: payloadRange,
                        payload: String(text[payloadRange]),
                        containerRange: Range(match.range, in: text)))
                }
            }
        }

        // 2b. Llama-style <function=name>{…}</function>
        if let regex = try? NSRegularExpression(
            pattern: #"<function=([A-Za-z0-9_]+)>\s*([\s\S]*?)\s*</function>"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 2 {
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let bodyRange = Range(match.range(at: 2), in: text) else { continue }
                let name = String(text[nameRange])
                let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let payload = body.hasPrefix("{")
                    ? "{\"name\":\"\(name)\",\"arguments\":\(body)}"
                    : "{\"name\":\"\(name)\",\"arguments\":{}}"
                candidates.append(Candidate(
                    range: bodyRange,
                    payload: payload,
                    containerRange: Range(match.range, in: text)))
            }
        }

        // 2c. Anthropic-style <invoke name="…"><parameter name="…">…</parameter>
        if let regex = try? NSRegularExpression(
            pattern: #"<invoke\s+name=["']?([A-Za-z0-9_]+)["']?\s*>([\s\S]*?)</invoke>"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 2 {
                guard let nameRange = Range(match.range(at: 1), in: text),
                      let bodyRange = Range(match.range(at: 2), in: text) else { continue }
                let name = String(text[nameRange])
                let arguments = invokeParameters(String(text[bodyRange]))
                candidates.append(Candidate(
                    range: bodyRange,
                    payload: "{\"name\":\"\(name)\",\"arguments\":\(arguments)}",
                    containerRange: Range(match.range, in: text)))
            }
        }

        // 3/4. Bare balanced JSON objects — only where nothing else claimed the range.
        candidates.append(contentsOf: bareObjects(in: text, excluding: candidates.map(\.range)))

        // Order by appearance, drop overlaps (fenced beats bare).
        candidates.sort { $0.range.lowerBound < $1.range.lowerBound }
        var result: [Candidate] = []
        var claimed: [Range<String.Index>] = []
        for candidate in candidates {
            let overlaps = claimed.contains { $0.overlaps(candidate.range) }
            if !overlaps {
                result.append(candidate)
                claimed.append(candidate.range)
            }
        }
        return result
    }

    /// Byte-depth scan for balanced `{ … }` regions outside already-claimed ranges.
    private static func bareObjects(in text: String, excluding claimed: [Range<String.Index>]) -> [Candidate] {
        var candidates: [Candidate] = []
        var depth = 0
        var start: String.Index?

        for index in text.indices {
            let character = text[index]
            if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" {
                depth = max(0, depth - 1)
                if depth == 0, let objectStart = start {
                    let range = objectStart..<text.index(after: index)
                    let overlaps = claimed.contains { $0.overlaps(range) }
                    if !overlaps {
                        candidates.append(Candidate(
                            range: range,
                            payload: String(text[range]),
                            containerRange: nil))
                    }
                    start = nil
                }
            }
        }
        return candidates
    }

    /// Removes an empty `<tool_call>` wrapper without touching a valid call,
    /// so the agent loop can still parse any real tool request that follows.
    static func strippingEmptyCallWrappers(from text: String) -> String {
        let ranges = emptyCallWrapperRanges(in: text)
        guard !ranges.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return removing(ranges: ranges, from: text)
    }

    /// Removes everything that parses as a tool call (fenced blocks,
    /// `<tool_call>` tags, bare JSON) from display text, leaving only prose.
    /// Used to sanitize assistant messages for the transcript: the model's
    /// raw call syntax is wire format, never user-facing content.
    static func strippingCalls(from text: String) -> String {
        var removals: [Range<String.Index>] = []
        for candidate in collectCandidates(text) {
            guard !decodePayload(candidate.payload).isEmpty else { continue }
            removals.append(candidate.containerRange ?? candidate.range)
        }
        // A model can emit an empty wrapper while deciding whether to call a
        // tool. It is still protocol noise, and leaving the tags behind makes
        // the final answer look like a broken XML transcript.
        removals.append(contentsOf: emptyCallWrapperRanges(in: text))
        guard !removals.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return removing(ranges: removals, from: text)
    }

    private static func emptyCallWrapperRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<tool_call>\s*</tool_call>"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text)
        }
    }

    private static func removing(
        ranges: [Range<String.Index>],
        from text: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        var lastRemovedEnd: String.Index?
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            // A valid wrapper and an empty-wrapper cleanup can overlap only
            // when a malformed provider repeats tags. Avoid duplicating the
            // intervening text if that happens.
            if let lastRemovedEnd, range.lowerBound < lastRemovedEnd { continue }
            result += text[cursor..<range.lowerBound]
            cursor = range.upperBound
            lastRemovedEnd = range.upperBound
        }
        result += text[cursor...]
        // Collapse the blank runs a removed block leaves behind.
        let collapsed = result.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the text ends inside what looks like an UNTERMINATED tool
    /// call: a `{"name": …` object whose braces never balance (the token
    /// ceiling cut the JSON off mid-call). Such a reply executed nothing —
    /// the loop should treat it as a protocol error, not a final answer.
    static func looksLikeToolCallFragment(_ text: String) -> Bool {
        guard let match = try? NSRegularExpression(pattern: #"\{\s*"name"\s*:"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range, in: text)
        else { return false }
        let tail = text[range.lowerBound...]
        var depth = 0
        var inString = false
        var escaped = false
        for character in tail {
            if escaped { escaped = false; continue }
            if escaped == false, character == "\\", inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if character == "{" { depth += 1 } else if character == "}" { depth -= 1 }
        }
        return depth > 0
    }

    /// Identifies explicit tool wire-format that did not produce a valid
    /// call. Ordinary JSON/prose is deliberately ignored: only a `tool`
    /// fence, a `<tool_call>` tag, or a clearly truncated name object is a
    /// protocol commitment that deserves an automatic repair turn.
    static func malformedCallReason(_ text: String) -> String? {
        if looksLikeToolCallFragment(text) {
            return "the JSON was cut off before its closing brace"
        }
        let lower = text.lowercased()
        let hasToolFence = lower.range(
            of: #"```\s*tool(?:\s|$)"#,
            options: .regularExpression) != nil
        let hasToolTag = lower.contains("<tool_call>")
            || lower.contains("</tool_call>")
            || lower.contains("<function=")
            || lower.contains("<invoke")
        guard hasToolFence || hasToolTag, parse(text).isEmpty else { return nil }
        return "the tool wrapper did not contain a valid name and JSON arguments object"
    }

    // MARK: Shape validation

    private struct Shaped: Equatable {
        let name: String
        let arguments: LFJSONValue
        var signature: String { name + "|" + arguments.encoded() }
    }

    /// Validates the normalized value is shaped like a tool call; accepts
    /// `name`+(`arguments`|`args`|`parameters`|`input`), OpenAI `tool_calls`
    /// envelopes, and `{"function": {"name": …, "arguments": …}}`.
    private static func shape(_ value: LFJSONValue) -> [Shaped] {
        guard let object = value.objectValue else { return [] }

        if let toolCalls = object["tool_calls"]?.arrayValue {
            return toolCalls.compactMap { entry in
                guard let entryObject = entry.objectValue else { return nil }
                let function = entryObject["function"]?.objectValue
                let name = function?["name"]?.stringValue ?? entryObject["name"]?.stringValue
                guard let name, !name.isEmpty else { return nil }
                let arguments = function?["arguments"] ?? entryObject["arguments"]
                return Shaped(name: name, arguments: coerceArguments(arguments))
            }
        }

        if let function = object["function"]?.objectValue,
           let name = function["name"]?.stringValue,
           !name.isEmpty
        {
            return [Shaped(name: name, arguments: coerceArguments(function["arguments"]))]
        }

        if let name = object["function"]?.stringValue, !name.isEmpty {
            return [Shaped(name: name, arguments: coerceArguments(
                object["arguments"] ?? object["args"] ?? object["parameters"] ?? object["input"]))]
        }

        let name = object["name"]?.stringValue
            ?? object["tool"]?.stringValue
            ?? object["tool_name"]?.stringValue
            ?? object["function_name"]?.stringValue
        guard let name, !name.isEmpty else { return [] }
        let arguments = coerceArguments(
            object["arguments"] ?? object["args"] ?? object["parameters"]
                ?? object["input"] ?? object["tool_input"])
        var fields = leftoverArguments(object)
        if case .object(let objectFields) = arguments {
            fields.merge(objectFields) { _, incoming in incoming }
        } else if case .string(let text) = arguments, !text.isEmpty {
            if fields.isEmpty {
                return [Shaped(name: name, arguments: arguments)]
            }
            if fields["question"] == nil, fields["query"] == nil, fields["prompt"] == nil {
                fields["question"] = .string(text)
            }
        }
        if !fields.isEmpty {
            return [Shaped(name: name, arguments: .object(fields))]
        }
        return [Shaped(name: name, arguments: arguments)]
    }

    private static func leftoverArguments(_ object: [String: LFJSONValue]) -> [String: LFJSONValue] {
        let reserved: Set<String> = [
            "name", "tool", "tool_name", "function_name", "function",
            "arguments", "args", "parameters", "input", "tool_input",
            "tool_calls", "id", "type", "index",
        ]
        return object.filter { !reserved.contains($0.key) }
    }

    private static func xmlTaggedCall(_ body: String) -> Shaped? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^([A-Za-z][A-Za-z0-9_]*)\s+([\s\S]+)$"#),
              let match = regex.firstMatch(
                in: body, range: NSRange(body.startIndex..., in: body)),
              let nameRange = Range(match.range(at: 1), in: body),
              let restRange = Range(match.range(at: 2), in: body)
        else { return nil }
        let name = String(body[nameRange])
        let rest = String(body[restRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if let xml = xmlArguments(rest) {
            return Shaped(name: name, arguments: xml)
        }
        if rest.hasPrefix("{") || rest.hasPrefix("["),
           let value = TolerantJSON.value(from: rest) {
            return Shaped(name: name, arguments: coerceArguments(value))
        }
        return nil
    }

    private static func xmlArguments(_ body: String) -> LFJSONValue? {
        if body.contains("<parameter") {
            let encoded = invokeParameters(body)
            if encoded != "{}" { return TolerantJSON.value(from: encoded) }
        }
        guard let regex = try? NSRegularExpression(
            pattern: #"<([A-Za-z][A-Za-z0-9_]*)>([\s\S]*?)</\1>"#) else {
            return nil
        }
        var object: [String: LFJSONValue] = [:]
        let range = NSRange(body.startIndex..., in: body)
        for match in regex.matches(in: body, range: range) where match.numberOfRanges > 2 {
            guard let nameRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body) else { continue }
            let key = String(body[nameRange])
            if key == "parameter" || key == "invoke" || key == "tool_call" { continue }
            object[key] = .string(String(body[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return object.isEmpty ? nil : .object(object)
    }

    private static func invokeParameters(_ body: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<parameter\s+name="([^"]+)">([\s\S]*?)</parameter>"#) else {
            return "{}"
        }
        var object: [String: LFJSONValue] = [:]
        let range = NSRange(body.startIndex..., in: body)
        for match in regex.matches(in: body, range: range) where match.numberOfRanges > 2 {
            guard let nameRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 2), in: body) else { continue }
            object[String(body[nameRange])] = .string(
                String(body[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return LFJSONValue.object(object).encoded()
    }

    /// Models sometimes emit arguments as a JSON *string* rather than an object.
    /// A non-JSON string (common for `ask_user`) is kept as a string so the
    /// question can still be recovered.
    private static func coerceArguments(_ value: LFJSONValue?) -> LFJSONValue {
        guard let value else { return .object([:]) }
        if case .object = value { return value }
        if let text = value.stringValue, let inner = TolerantJSON.value(from: text) {
            if case .object = inner { return inner }
        }
        if case .string = value { return value }
        return .object([:])
    }
}

private extension ParsedToolCall {
    var signature: String { name + "|" + argumentsJSON }
}

/// Wire-format serializer for tool calls — the inverse of `ToolParser.parse`.
/// Engines that receive tool calls as structured events instead of text
/// (MLXLMCommon's `.toolCall` generations) use this to hand the agent loop
/// text its parser recognizes.
enum ToolCallText {
    static func serialize(name: String, argumentsJSON: String) -> String {
        let safeName = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "<tool_call>\n{\"name\": \"\(safeName)\", \"arguments\": \(argumentsJSON)}\n</tool_call>"
    }
}
