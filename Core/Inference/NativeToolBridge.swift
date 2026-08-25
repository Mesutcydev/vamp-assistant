import Foundation

/// Structured tool spec sent to BYOK APIs as native function-calling.
/// The loop still parses the existing text protocol — this bridge converts
/// streamed `tool_calls` / `tool_use` back into that wire format.
struct NativeToolSpec: Sendable, Equatable {
    var name: String
    var description: String
    var schemaText: String

    init(name: String, description: String, schemaText: String) {
        self.name = name
        self.description = description
        self.schemaText = schemaText
    }

    init(tool: any AgentTool) {
        self.init(name: tool.name, description: tool.summary, schemaText: tool.schemaText)
    }
}

/// Engines that can advertise native tools to a remote API.
protocol NativeToolConfigurable: AnyObject {
    func configureNativeTools(_ tools: [NativeToolSpec])
}

enum NativeToolBridge {

    /// OpenAI `tools: [{type:function, function:{name,description,parameters}}]`.
    struct OpenAITool: Encodable, Sendable {
        var type: String = "function"
        var function: Function
        struct Function: Encodable, Sendable {
            var name: String
            var description: String
            var parameters: JSONBox
        }
    }

    /// Anthropic `tools: [{name, description, input_schema}]`.
    struct AnthropicTool: Encodable, Sendable {
        var name: String
        var description: String
        var input_schema: JSONBox
    }

    /// Gemini groups function declarations inside one `tools` entry.
    struct GeminiTool: Codable, Sendable {
        var functionDeclarations: [FunctionDeclaration]

        struct FunctionDeclaration: Codable, Sendable {
            var name: String
            var description: String
            var parameters: JSONBox
        }
    }

    static func openAITools(from specs: [NativeToolSpec]) -> [OpenAITool] {
        specs.map { spec in
            OpenAITool(function: .init(
                name: spec.name,
                description: spec.description,
                parameters: JSONBox.parse(spec.schemaText)))
        }
    }

    static func anthropicTools(from specs: [NativeToolSpec]) -> [AnthropicTool] {
        specs.map { spec in
            AnthropicTool(
                name: spec.name,
                description: spec.description,
                input_schema: JSONBox.parse(spec.schemaText))
        }
    }

    static func geminiTools(from specs: [NativeToolSpec]) -> [GeminiTool] {
        guard !specs.isEmpty else { return [] }
        return [GeminiTool(functionDeclarations: specs.map { spec in
            GeminiTool.FunctionDeclaration(
                name: spec.name,
                description: spec.description,
                parameters: JSONBox.parse(spec.schemaText).geminiFunctionSchema())
        })]
    }

    /// Fold streamed fragments (by index) into the first complete call and
    /// emit the text fence `ToolParser` already understands.
    static func serializeAccumulated(_ fragments: [Int: (name: String, arguments: String)]) -> String? {
        let ordered = fragments.sorted { $0.key < $1.key }
        guard let first = ordered.first, !first.value.name.isEmpty else { return nil }
        let args = first.value.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = args.isEmpty ? "{}" : args
        return ToolCallText.serialize(name: first.value.name, argumentsJSON: json)
    }

    /// Best-effort string value from a still-growing JSON object. Used to
    /// stream `ask_user` questions while native `tool_calls` fragments arrive.
    static func partialJSONString(in json: String, keys: [String]) -> String? {
        for key in keys {
            let needle = "\"\(key)\""
            var search = json.startIndex
            while let keyRange = json.range(of: needle, range: search..<json.endIndex) {
                var index = keyRange.upperBound
                while index < json.endIndex, json[index].isWhitespace {
                    index = json.index(after: index)
                }
                guard index < json.endIndex, json[index] == ":" else {
                    search = keyRange.upperBound
                    continue
                }
                index = json.index(after: index)
                while index < json.endIndex, json[index].isWhitespace {
                    index = json.index(after: index)
                }
                guard index < json.endIndex, json[index] == "\"" else { return nil }
                index = json.index(after: index)
                var result = ""
                var escaped = false
                while index < json.endIndex {
                    let character = json[index]
                    if escaped {
                        switch character {
                        case "n": result.append("\n")
                        case "t": result.append("\t")
                        case "r": result.append("\r")
                        case "\"": result.append("\"")
                        case "\\": result.append("\\")
                        default: result.append(character)
                        }
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        return result
                    } else {
                        result.append(character)
                    }
                    index = json.index(after: index)
                }
                return result.isEmpty ? nil : result
            }
        }
        return nil
    }

    static func askUserQuestionProgress(
        name: String,
        arguments: String
    ) -> String? {
        guard name == "ask_user" else { return nil }
        return partialJSONString(
            in: arguments,
            keys: ["question", "query", "prompt", "text", "message"])
    }

    /// Recursive JSON so we can embed a tool's schemaText as a real object,
    /// not a string, in the provider payload.
    enum JSONBox: Codable, Sendable, Equatable {
        case object([String: JSONBox])
        case array([JSONBox])
        case string(String)
        case number(Double)
        case bool(Bool)
        case null

        static func parse(_ text: String) -> JSONBox {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = trimmed.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data)
            else {
                return .object(["type": .string("object"), "properties": .object([:])])
            }
            return from(any)
        }

        /// Gemini's function-declaration schema is a subset of JSON Schema.
        /// `additionalProperties` and `$schema` are the common 400 causes.
        func geminiFunctionSchema() -> JSONBox {
            switch self {
            case .object(let object):
                var cleaned: [String: JSONBox] = [:]
                for (key, value) in object {
                    if key == "additionalProperties" || key == "$schema" || key == "$id" { continue }
                    cleaned[key] = value.geminiFunctionSchema()
                }
                return .object(cleaned)
            case .array(let array):
                return .array(array.map { $0.geminiFunctionSchema() })
            default:
                return self
            }
        }

        static func from(_ any: Any) -> JSONBox {
            switch any {
            case let dict as [String: Any]:
                .object(dict.mapValues { from($0) })
            case let list as [Any]:
                .array(list.map { from($0) })
            case let text as String:
                .string(text)
            case let number as NSNumber:
                // Bool is bridged as NSNumber — distinguish it.
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    .bool(number.boolValue)
                } else {
                    .number(number.doubleValue)
                }
            default:
                .null
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let object): try container.encode(object)
            case .array(let array): try container.encode(array)
            case .string(let string): try container.encode(string)
            case .number(let number): try container.encode(number)
            case .bool(let flag): try container.encode(flag)
            case .null: try container.encodeNil()
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let object = try? container.decode([String: JSONBox].self) {
                self = .object(object)
            } else if let array = try? container.decode([JSONBox].self) {
                self = .array(array)
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unsupported JSON value")
            }
        }
    }
}
