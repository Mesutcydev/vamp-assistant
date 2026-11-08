import Foundation

/// Local file inference is separate from chat history. Media never goes to a
/// provider, and speech is returned as a WAV artifact rather than hidden text.
public struct OmniMediaRequest: Sendable {
    enum Kind: String, Sendable { case audio, video, image, speech }
    var kind: Kind
    var prompt: String
    var data: Data = Data()
    var mimeType: String = "application/octet-stream"
    var language: String? = nil
    var voice: String? = nil
}

public struct OmniMediaResult: Sendable {
    var text: String = ""
    var wav: Data? = nil
}

struct LocalOmniClient: Sendable {
    let baseURL: URL
    static let inputLimit = 64 * 1024 * 1024
    static let audioLimit = 32 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            if case .unavailable(let message) = self { return message }
            return nil
        }
    }

    func perform(_ input: OmniMediaRequest) async throws -> OmniMediaResult {
        guard input.data.count <= Self.inputLimit, input.prompt.utf8.count <= 16_384 else {
            throw Failure.unavailable("Media exceeds 64 MB or the prompt exceeds 16 KB.")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (models, modelResponse) = try await session.data(from: baseURL.appendingPathComponent("v1/models"))
        try Self.check(modelResponse, data: models)
        try Self.requireCapability(input.kind, models: models)
        if input.kind == .speech {
            return try await speech(input, session: session)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.mediaBody(input)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        return OmniMediaResult(text: try Self.visibleText(data))
    }

    static func requireCapability(_ kind: OmniMediaRequest.Kind, models: Data) throws {
        let json = try JSONSerialization.jsonObject(with: models) as? [String: Any]
        let model = (json?["data"] as? [[String: Any]])?.first
        let architecture = model?["architecture"] as? [String: Any]
        let key = kind == .speech ? "output_modalities" : "input_modalities"
        let modality = kind == .speech ? "audio" : kind.rawValue
        guard (architecture?[key] as? [String])?.contains(modality) == true else {
            throw Failure.unavailable("The loaded runtime does not report \(modality) \(kind == .speech ? "output" : "input"). Load LFM3 Omni GGUF with its matching vision/audio projector and the current compatibility runtime.")
        }
    }

    static func mediaBody(_ input: OmniMediaRequest) throws -> Data {
        let encoded = input.data.base64EncodedString()
        let media: [String: Any]
        switch input.kind {
        case .image:
            media = ["type": "image_url", "image_url": ["url": "data:\(input.mimeType);base64,\(encoded)"]]
        case .audio, .video:
            let type = "input_\(input.kind.rawValue)"
            media = ["type": type, type: ["data": encoded]]
        case .speech:
            throw Failure.unavailable("Speech uses the TTS endpoint.")
        }
        return try JSONSerialization.data(withJSONObject: [
            "model": "beetcode", "stream": false, "temperature": 0,
            "max_tokens": 1024, "reasoning_effort": "none",
            "messages": [
                ["role": "system", "content": "Respond in text. For video, use both the frames and their soundtrack."],
                ["role": "user", "content": [media, ["type": "text", "text": input.prompt]]],
            ],
        ])
    }

    static func visibleText(_ data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        if let text = message?["content"] as? String, !text.isEmpty { return text }
        if let parts = message?["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        throw Failure.unavailable("Local media inference returned no text.")
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.unavailable("Local media request failed: \(String(decoding: data.prefix(2048), as: UTF8.self))")
        }
    }

    private func speech(_ input: OmniMediaRequest, session: URLSession) async throws -> OmniMediaResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.speechBody(input)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data: data)
        try Self.validateWAV(data)
        return OmniMediaResult(wav: data)
    }

    static func speechBody(_ input: OmniMediaRequest) throws -> Data {
        var body: [String: Any] = ["input": input.prompt, "response_format": "wav", "stream": false, "n_predict": 2048]
        if let language = input.language { body["lang"] = language }
        if let voice = input.voice { body["voice"] = voice }
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func validateWAV(_ data: Data) throws {
        guard data.count >= 44, data.count <= audioLimit,
              data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw Failure.unavailable("Local speech returned invalid or oversized WAV data; no file was saved.")
        }
    }
}
